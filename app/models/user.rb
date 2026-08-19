class User < ApplicationRecord
  has_many :daily_exercises, dependent: :destroy
  has_many :daily_responses, dependent: :destroy, inverse_of: :user
  has_many :api_usages,      dependent: :destroy
  has_many :concept_masteries, dependent: :destroy

  # Encrypt the user's provider API key at rest. Requires RAILS_MASTER_KEY /
  # credentials to be set (standard Rails setup).
  encrypts :api_key

  LANGUAGES = %w[ruby_rails javascript mixed].freeze

  DEFAULT_TIME_ZONE = "America/New_York".freeze

  validates :email, presence: true, uniqueness: { case_sensitive: false },
                    format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :name,  presence: true
  validates :skill_level, inclusion: { in: %w[beginner developing solid strong] }
  validates :provider, inclusion: { in: %w[anthropic gemini fake] }, allow_nil: true
  validates :language, inclusion: { in: LANGUAGES }
  validate :time_zone_must_be_loadable

  before_save { email.downcase! }

  scope :active, -> { where(anonymized_at: nil) }

  TOKEN_EXPIRY = 15.minutes
  LOGIN_CODE_MAX_ATTEMPTS = 5

  attr_reader :raw_login_code

  # ── Magic link ────────────────────────────────────────────────────────────
  def generate_login_token!
    raw_token = SecureRandom.urlsafe_base64(32)
    @raw_login_code = format("%06d", SecureRandom.random_number(1_000_000))
    update!(
      login_token_digest:   BCrypt::Password.create(raw_token),
      login_token_sent_at:  Time.current,
      login_code_digest:    BCrypt::Password.create(@raw_login_code),
      login_code_attempts:  0
    )
    raw_token
  end

  def self.find_by_login_token(raw_token)
    # We can't query by the digest directly since each BCrypt hash is salted,
    # so we do a two-step lookup: find candidates sent within the expiry window,
    # then verify the digest in Ruby.
    candidates = active.where("login_token_sent_at > ?", TOKEN_EXPIRY.ago)
                       .where.not(login_token_digest: nil)
    candidates.find { |u| BCrypt::Password.new(u.login_token_digest) == raw_token }
  end

  # Same underlying token record as the link — a different presentation, not a
  # separate or weaker mechanism. Wrong guesses count against
  # LOGIN_CODE_MAX_ATTEMPTS; hitting it invalidates the code AND the link,
  # forcing a fresh request rather than leaving a guessable code live.
  def self.authenticate_login_code(email:, code:)
    candidates = active.where("login_token_sent_at > ?", TOKEN_EXPIRY.ago)
                       .where.not(login_code_digest: nil)
    user = candidates.find_by(email: email.to_s.strip.downcase)
    return nil unless user

    if BCrypt::Password.new(user.login_code_digest) == code.to_s.strip
      user.clear_login_token!
      return user
    end

    user.increment!(:login_code_attempts)
    user.clear_login_token! if user.login_code_attempts >= LOGIN_CODE_MAX_ATTEMPTS
    nil
  end

  def clear_login_token!
    update!(
      login_token_digest:   nil,
      login_token_sent_at:  nil,
      login_code_digest:    nil,
      login_code_attempts:  0
    )
  end

  # ── Account deletion ──────────────────────────────────────────────────────
  # Self-service deletion anonymizes in place rather than destroying: the
  # user's exercises, responses (answers, ai_review, concept_tags) and API
  # usage stay linked by user_id for aggregate stats, but nothing on the row
  # identifies a person any more. Never call destroy here — the association
  # `dependent: :destroy` would take that history with it.
  def anonymized?
    anonymized_at.present?
  end

  # Suppresses every generation the user didn't ask for — the cron batch and
  # the dashboard's auto-trigger. An explicit /generate or /regenerate click
  # still runs while paused.
  def paused_generation_at?
    paused_generation_at.present?
  end

  # Idempotent under concurrency: `with_lock` takes a row lock and reloads
  # before the check, so two in-flight calls (double-click, retry from another
  # tab) serialize — the second sees `anonymized?` already true, returns false,
  # and never overwrites the original `anonymized_at`. Returns true only on the
  # call that actually anonymized the row.
  def anonymize!
    with_lock do
      return false if anonymized?

      update!(
        email:               "deleted-user-#{id}@anonymized.local",
        name:                "Deleted user",
        api_key:             nil,
        login_token_digest:  nil,
        login_token_sent_at: nil,
        login_code_digest:   nil,
        login_code_attempts: 0,
        anonymized_at:       Time.current
      )
    end
    true
  end

  # ── API key ───────────────────────────────────────────────────────────────
  def api_key_present?
    api_key.present?
  end

  # ── Recent performance for prompt context ─────────────────────────────────
  # Last N sessions by count, not a calendar window — matches the "last 10
  # sessions" contract embedded verbatim in AiService's generation prompt.
  def recent_performance(limit: 10)
    recent_daily_responses(limit).map do |r|
      problem_set = r.daily_exercise&.problem_set || {}
      scenarios = ExerciseSection.keys.filter_map do |section|
        problem_set.dig(section, "scenario").presence
      end
      ai_ratings = r.concept_tags.keys.index_with { |section| r.ai_rating_for(section) }.compact
      {
        date:              r.date.to_s,
        feedback:          r.feedback_text,
        concepts:          r.concept_tags,
        scenarios:         scenarios,
        sections_answered: r.answered_sections.size,
        sections_total:    r.section_keys.size,
        self_ratings:      r.section_ratings,
        ai_ratings:        ai_ratings
      }
    end
  end

  # Recent exercises and whether each was answered, newest first, excluding
  # today (which has had no chance to be). SectionCount/SectionRotation are
  # pure and take this as an argument rather than touching the database
  # themselves.
  def recent_exercise_history(limit:)
    daily_exercises
      .includes(:daily_response)
      .where(date: ...Date.current)
      .order(date: :desc)
      .limit(limit)
      .map do |exercise|
        ExerciseHistoryEntry.new(
          section_keys: exercise.active_section_keys,
          answered:     exercise.daily_response&.answered_sections&.size
        )
      end
  end

  # Concepts still needing reinforcement, resolved on each concept's single
  # most-recent occurrence — not cumulative history, so a concept mastered
  # weeks ago never resurfaces because of an old bad day. Mastery requires
  # both signals to explicitly agree the user is solid; an absent signal
  # never counts toward mastery (uncertain data defaults to reinforcement).
  # Total absence of both signals is out of scope, same as an unrated
  # concept today.
  #
  # `bucket:`/`exclude_buckets:` scope the result by ConceptBucket — added for
  # the fourth slot's independent reinforcement track, which must never mix
  # with the three-slot vocabulary. Both default to a no-op filter, so every
  # caller that doesn't pass them (every
  # caller as of this comment) sees identical behavior to before either
  # keyword existed. Marking a concept resolved happens before either filter
  # runs; that's safe for the special ConceptBucket vocabularies (architecture,
  # plan_review, ambiguity_hunt, pseudocode_to_code) because each is disjoint from every other
  # vocabulary, including both language vocabularies — a filtered-out
  # most-recent occurrence implies every older occurrence of that same concept
  # would be filtered too, so dedup and filter order can never disagree. It is
  # NOT safe for a language bucket ("ruby_rails"/"javascript"): RAILS_CONCEPTS
  # and JS_CONCEPTS share a few concept names (e.g. over_mocking), so for a
  # mixed-language user the same concept can carry different buckets on
  # different days, and dedup-before-filter could drop an occurrence the
  # filter should have kept. `bucket:`/`exclude_buckets:` are for the special
  # buckets only; no caller today passes a language bucket.
  #
  # The vocabulary-membership filter DOES apply to language buckets, and so
  # runs BEFORE the dedup marker rather than after it: an occurrence naming a
  # concept that has left its own bucket's vocabulary is not an occurrence of a
  # live concept at all, and must not consume the dedup slot that an older
  # occurrence in a bucket where the name is still valid would fill.
  def concepts_needing_reinforcement(limit: 10, bucket: nil, exclude_buckets: [])
    resolved = {}
    result   = []

    recent_daily_responses(limit).each do |r|
      r.concept_tags.each do |section, concept|
        next if concept.blank? || concept == "other"

        tag_bucket = ConceptBucket.for(section, r.daily_exercise&.language)
        next unless still_in_vocabulary?(concept, tag_bucket)
        next if resolved.key?(concept)
        resolved[concept] = true

        next if r.self_rating_for(section).nil? && r.ai_rating_for(section).nil? # out of scope

        next if r.self_rating_favorable?(section) && r.ai_rating_favorable?(section) # mastered

        next if bucket && tag_bucket != bucket
        next if exclude_buckets.include?(tag_bucket)

        tier = concept_masteries.find_by(concept: concept, language: tag_bucket)&.tier || "standard"
        next if tier == "paused"

        result << { concept: concept, tier: tier }
      end
    end

    result
  end

  # Mastered concepts whose scheduled re-check has come due, most overdue first.
  # Bucket-scoped by the caller: an architecture concept has no valid home outside
  # the architecture third, and a ruby_rails concept must not surface on a
  # JavaScript day.
  def concepts_due_for_retention_check(bucket:, limit:)
    concept_masteries
      .in_bucket(bucket)
      .where.not(next_retention_check_on: nil)
      .where(next_retention_check_on: ..Date.current)
      .order(:next_retention_check_on)
      .limit(limit)
  end

  # Due concepts that have crossed the "meaningfully overdue" threshold: overdue
  # by RETENTION_OVERDUE_THRESHOLD_MULTIPLIER × the concept's OWN current
  # retention_interval_days, on top of its due date. Used only to decide whether
  # to reserve a reinforcement slot for retention — a merely-due check is not
  # enough on its own (see AiService#generate_exercise). retention_interval_days
  # is nullable (cleared whenever a check fails), so null-interval rows are
  # excluded explicitly rather than risking a null comparison silently matching.
  def concepts_overdue_for_retention_check(bucket:)
    concept_masteries
      .in_bucket(bucket)
      .where.not(next_retention_check_on: nil)
      .where.not(retention_interval_days: nil)
      .where(
        "next_retention_check_on + (retention_interval_days * ?) <= ?",
        ConceptMastery::RETENTION_OVERDUE_THRESHOLD_MULTIPLIER, Date.current
      )
  end

  # Single-query, memoized index of every submitted response's concept exposures,
  # keyed [concept, bucket] => the distinct dates the concept appeared (in query
  # order, not sorted — callers only ever count them). Built once per User
  # instance so a page rendering many responses (history) never queries per section.
  def concept_exposure_index
    @concept_exposure_index ||= begin
      index = Hash.new { |hash, key| hash[key] = [] }
      daily_responses.where.not(submitted_at: nil).joins(:daily_exercise)
                     .pluck(:date, :concept_tags, "daily_exercises.language")
                     .each do |date, tags, language|
        (tags || {}).each do |section, concept|
          next if concept.blank? || concept == "other"
          bucket = ConceptBucket.for(section, language)
          # Union, not append: a concept tagged on multiple sections the same
          # day is one exposure, not one per section (matches ConceptMastery#record_review!).
          index[[ concept, bucket ]] |= [ date ]
        end
      end
      index
    end
  end

  def concept_exposure_count(concept, bucket, on_or_before:)
    concept_exposure_index.fetch([ concept, bucket ], []).count { |d| d <= on_or_before }
  end

  # ── Language preference ────────────────────────────────────────────────────
  # Resolves the day's actual generation language. Pinned preferences return
  # themselves. "mixed" alternates by flipping the most recent PRIOR
  # exercise's language (excluding today's own row, so calling this multiple
  # times for the same day — e.g. on regenerate — stays consistent as long as
  # callers pass the result through rather than recomputing mid-day).
  def language_for_today
    return language unless language == "mixed"

    last = daily_exercises.where.not(date: Date.current).order(date: :desc).first
    return "ruby_rails" unless last

    last.language == "ruby_rails" ? "javascript" : "ruby_rails"
  end

  # ── Daily streak ───────────────────────────────────────────────────────────
  # Consecutive weekdays with a submitted response, derived on read by walking
  # back from today (in the caller's zone — controllers and jobs wrap calls in
  # Time.use_zone). Weekends never break the chain, and neither does today
  # while it is still unsubmitted; only a past weekday whose exercise went
  # unsubmitted resets it. A weekday with no exercise at all (pre-signup,
  # failed generation) neither counts nor breaks.
  def current_streak
    submitted = daily_responses.where.not(submitted_at: nil).pluck(:date).to_set
    return 0 if submitted.empty?

    exercised = daily_exercises.pluck(:date).to_set
    earliest = submitted.min
    streak = 0
    day = Date.current
    while day >= earliest
      if day.on_weekend?
        # Neither breaks the streak nor counts toward it — the empty branch is
        # what skips the day, so collapsing it into the elsif would end streaks
        # every Saturday.
      elsif submitted.include?(day)
        streak += 1
      elsif exercised.include?(day) && day != Date.current
        break
      end
      day -= 1
    end
    streak
  end

  # ── Timezone ────────────────────────────────────────────────────────────────
  # Resolved zone for computing this user's "today". Blank until the browser
  # detects it or the user sets it manually, so fall back to the team default.
  def effective_time_zone
    time_zone.presence || DEFAULT_TIME_ZONE
  end

  # ── Display ────────────────────────────────────────────────────────────────
  def provider_label
    # default: falls back to the "unknown" key ("AI") for any provider value
    # without its own translation — including legacy/invalid data that bypassed
    # validation — so the UI never shows a "translation missing" string.
    I18n.t("providers.#{provider.presence || 'unknown'}", default: :"providers.unknown")
  end

  private

  # concept_tags is persisted provider output, so it keeps the name a section
  # was tagged with even after that concept leaves the vocabulary. Reinforcing
  # one the generator can no longer tag wastes an entry AND a retention slot,
  # since DailyPlan sizes retention as whatever the day's non-fourth sections
  # can host minus the reinforcement entries that claim them.
  #
  # A nil bucket passes, because vocabulary_for raises on nil and there is no
  # vocabulary to check against. Reaching it needs both a nil language and a
  # missing exercise row, which the NOT NULL foreign key on
  # daily_responses.daily_exercise_id makes unreachable — this keeps an
  # unreachable state from raising during generation rather than describing a
  # case that happens.
  def still_in_vocabulary?(concept, bucket)
    return true if bucket.nil?
    ConceptBucket.vocabulary_for(bucket).include?(concept)
  end

  # Shared by #recent_performance and #concepts_needing_reinforcement so
  # neither issues its own duplicate "last N sessions" query.
  def recent_daily_responses(limit)
    daily_responses.includes(:daily_exercise).order(date: :desc).limit(limit)
  end

  def time_zone_must_be_loadable
    return if time_zone.blank? # blank/nil = not yet detected; allowed
    errors.add(:time_zone, "is not a valid time zone") if Time.find_zone(time_zone).nil?
  end
end
