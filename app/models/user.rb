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

  LOGIN_CODE_EXPIRY = 15.minutes
  LOGIN_CODE_MAX_ATTEMPTS = 5

  # The one phrasing of the window, so the flash and the email cannot drift
  # from the constant they describe. ActiveSupport::Duration#inspect is the
  # humanized form ("15 minutes"), not a debug dump.
  def self.login_code_expiry_in_words
    LOGIN_CODE_EXPIRY.inspect
  end

  # ── Login code ────────────────────────────────────────────────────────────
  def generate_login_code!
    raw_code = format("%06d", SecureRandom.random_number(1_000_000))
    update!(
      login_code_sent_at:  Time.current,
      login_code_digest:   BCrypt::Password.create(raw_code),
      login_code_attempts: 0
    )
    raw_code
  end

  # Wrong guesses count against LOGIN_CODE_MAX_ATTEMPTS; hitting it
  # invalidates the code, forcing a fresh request rather than leaving a
  # guessable one live.
  #
  # Serialized under a row lock, the same way #anonymize! is. Read, compare and
  # invalidate are one decision, and unserialized they are three statements a
  # second request can interleave with: every request that reads the digest
  # before the first invalidation commits redeems the same code. Measured, not
  # reasoned — with the lock removed, eight parallel posts of one correct code
  # authenticate five times (see spec/models/login_code_concurrency_spec.rb).
  # Those same interleaved reads each spend a guess against a live digest,
  # which is why the lock matters more here than it would for a 256-bit token.
  # It spans one BCrypt compare, which a login endpoint can afford.
  def self.authenticate_login_code(email:, code:)
    user = active.find_by(email: email.to_s.strip.downcase)
    return nil unless user

    user.with_lock do
      return nil if user.login_code_digest.nil?
      return nil if user.login_code_sent_at.nil? || user.login_code_sent_at < LOGIN_CODE_EXPIRY.ago

      if BCrypt::Password.new(user.login_code_digest) == code.to_s.strip
        user.clear_login_code!
        return user
      end

      user.increment!(:login_code_attempts)
      user.clear_login_code! if user.login_code_attempts >= LOGIN_CODE_MAX_ATTEMPTS
      nil
    end
  end

  def clear_login_code!
    update!(
      login_code_sent_at:  nil,
      login_code_digest:   nil,
      login_code_attempts: 0
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

  # The one home for "today's recorded generation failure no longer describes
  # anything". Both callers had this byte-identical — ResponsesController after
  # a review succeeds, and #carry_forward once a recovered set occupies today —
  # and the guard is part of the rule, not the caller's: an error from an
  # earlier day is history, not a stale banner. Scoped to the same day because
  # DashboardController#show only reports it when it matches today.
  def clear_stale_generation_error!
    return unless last_generation_error_date == Date.current

    update!(last_generation_error_date: nil, last_generation_error: nil)
  end

  # Suppresses every generation the user didn't ask for — the cron batch and
  # the dashboard's auto-trigger. An explicit /generate or /regenerate click
  # still runs while paused.
  def paused_generation_at?
    paused_generation_at.present?
  end

  # Lifts the pause and brings the set it stranded forward. Clearing the flag
  # alone would only unblock the next cycle: every "today's exercise" lookup is
  # `for_date`, so a set generated the morning of the pause is unreachable the
  # next day — the dashboard won't render it and ResponsesController#create
  # 404s — while still reading as a skip to SectionCount and as a break to
  # #current_streak. Re-dating it to today makes it an ordinary today exercise
  # and drops it out of both windows at once, since #recent_exercise_history
  # excludes today and #current_streak exempts it.
  #
  # Returns the exercise it moved, or nil when there was nothing to move.
  #
  # Accepted: the set then counts toward the resume day's completion window and
  # streak rather than the day it was generated.
  #
  # `with_lock` for the same reason as #anonymize!: it reloads under a row lock,
  # so a double-tapped call serializes and the second one sees the pause
  # already cleared, finds no held set, and no-ops.
  #
  # That FOR UPDATE also settles the race against a generation running for this
  # user, though indirectly: daily_exercises has a foreign key to users, so
  # inserting today's exercise needs a FOR KEY SHARE lock on this same row,
  # which FOR UPDATE conflicts with. A generator therefore cannot commit
  # between the `exists?` check and the move — it either committed before the
  # lock (and `exists?` sees it, so nothing moves) or blocks until after
  # (and loses its own set to the unique index, which
  # GenerateDailyExercisesJob already treats as "generated concurrently").
  # Resume wins, which is the right way round: the held set carries the user's
  # own draft answers, a fresh one would not.
  #
  # Runs in the user's own zone rather than trusting the caller's, unlike the
  # read-only #recent_exercise_history and #current_streak: this one *writes* a
  # date that has to be the user's today, and it also compares against the
  # pause's local date, so a caller with a different ambient zone would not
  # merely read oddly — it would either no-op silently or file the set under a
  # day that is not the user's.
  def resume_generation!
    Time.use_zone(effective_time_zone) do
      with_lock do
        held = held_exercise
        update!(paused_generation_at: nil)
        next if held.nil? || daily_exercises.for_date.exists?

        carry_forward(held)
      end
    end
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
        login_code_sent_at:  nil,
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

  # Moves the held set onto today. The draft moves with its exercise: a response
  # is only ever created against today's exercise, so leaving it behind would
  # let #create build a second one for the same exercise while `has_one`
  # returned the stale row. Both regeneration columns clear, for the same reason:
  # they describe the row's *day*, not the set. `regenerated_at` would hide the
  # Generate-new-set button behind something false ("You've already generated
  # a new set today"), and `regenerating_since` is worse than cosmetic — a
  # RegenerateExerciseJob stranded from the pause day gates only on
  # `exercise&.regenerating_since` after resolving `for_date`, so a leftover
  # claim would let it replace the carried-forward problem_set and destroy the
  # very draft response this went to the trouble of moving.
  #
  # Clearing a same-day generation error is part of establishing today's
  # exercise, not an extra: /generate is not pause-gated, so a paused user can
  # click it, have the job fail with no exercise for today to suppress the
  # report (see GenerateDailyExercisesJob#persist_failure), and then resume —
  # leaving DashboardController#show's `last_generation_error_date` check
  # rendering "Couldn't generate a new set" above the perfectly good set this
  # just recovered, the exact banner persist_failure exists to avoid.
  #
  # A SAVEPOINT so a failed move rolls back only itself, leaving the
  # pause-clearing UPDATE committed — otherwise a user who hit this would be
  # both 500ing and still paused. Both rescues are defence in depth rather than
  # the mechanism: #resume_generation!'s row lock already serializes generation
  # against this. Both classes are caught because `date` uniqueness is enforced
  # twice — the model validation raises RecordInvalid before the index ever
  # raises RecordNotUnique — and RecordInvalid is re-raised unless it is that
  # validation, so an unrelated invalid record still surfaces.
  def carry_forward(held)
    transaction(requires_new: true) do
      held.daily_response&.update!(date: Date.current)
      held.update!(date: Date.current, regenerated_at: nil, regenerating_since: nil)
      clear_stale_generation_error!
    end
    held
  rescue ActiveRecord::RecordNotUnique
    nil
  rescue ActiveRecord::RecordInvalid => e
    raise unless e.record.errors[:date].present?
    nil
  end


  # The set the pause stranded: the newest unsubmitted exercise dated on or
  # after the pause and before today. Scoped to the pause rather than to "any
  # unsubmitted exercise" because a day abandoned before pausing was abandoned,
  # not held. The range excludes today so a set already dated today is a no-op
  # instead of a collision with itself.
  def held_exercise
    return nil unless paused_generation_at?

    paused_on = paused_generation_at.in_time_zone(Time.zone).to_date
    daily_exercises
      .left_joins(:daily_response)
      .where(date: paused_on...Date.current)
      .where(daily_responses: { submitted_at: nil })
      .order(date: :desc)
      .first
  end

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
