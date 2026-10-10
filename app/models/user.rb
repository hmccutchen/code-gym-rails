class User < ApplicationRecord
  has_many :daily_exercises, dependent: :destroy
  has_many :daily_responses, dependent: :destroy, inverse_of: :user
  has_many :api_usages,      dependent: :destroy
  has_many :concept_masteries, dependent: :destroy
  has_many :push_subscriptions, dependent: :destroy
  belongs_to :invite_code, optional: true

  # One key per provider, encrypted as a whole; needs RAILS_MASTER_KEY or credentials.
  serialize :api_keys, coder: JSON
  encrypts :api_keys

  # Kept while old code serves through the pre-deploy migration; a later migration drops it.
  self.ignored_columns += [ "api_key" ]

  LANGUAGES = %w[ruby_rails javascript mixed].freeze
  SKILL_LEVELS = KindDifficulty::LEVELS

  # Read through #skill_level; rewriting rows in the same deploy would fail the old code's validation.
  LEGACY_SKILL_LEVELS = {
    "beginner" => "junior", "developing" => "junior", "solid" => "senior", "strong" => "principal_engineer"
  }.freeze

  DEFAULT_TIME_ZONE = "America/New_York".freeze

  # nil is Automatic: DaySize sizes the day from completion and the competency gate.
  DAILY_SECTION_COUNTS = (SectionCount::FLOOR..ExerciseSection::MAX_SECTIONS)
  # What Setup posts for Automatic, since a radio has no nil value.
  AUTOMATIC_SECTION_COUNT = "automatic".freeze

  validates :email, presence: true, uniqueness: { case_sensitive: false },
                    format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :name,  presence: true
  # Clamped, not refused: sign-up creates the row from a typed name, so a refusal would fail the login.
  before_validation :clean_name, if: :name_changed?
  validates :skill_level, inclusion: { in: SKILL_LEVELS }
  validates :provider, inclusion: { in: ->(_) { AiProvider.keys } }, allow_nil: true
  validate :api_keys_name_providers, if: :api_keys_changed?
  validate :provider_has_a_stored_key, if: -> { provider_changed? || api_keys_changed? }
  validates :language, inclusion: { in: LANGUAGES }
  validates :learning_track, inclusion: { in: LearningTrack::VALUES }, allow_nil: true
  validate :time_zone_must_be_loadable
  # Only on change: a kind retired from the registry would otherwise make every user naming it unsaveable, logins included.
  validate :section_kind_weights_name_rotatable_kinds,   if: :section_kind_weights_changed?
  validate :excluded_section_kinds_name_rotatable_kinds, if: :excluded_section_kinds_changed?
  validate :every_slot_keeps_a_kind,                     if: :excluded_section_kinds_changed?
  validate :section_kind_levels_name_section_kinds,      if: :section_kind_levels_changed?
  validate :locked_section_kinds_name_section_kinds,     if: :locked_section_kinds_changed?
  validate :locks_have_levels, if: -> { section_kind_levels_changed? || locked_section_kinds_changed? }
  validate :display_preferences_name_known_options, if: :display_preferences_changed?
  # Only on change, so a later range change can't make a stored row unsavable; DaySize clamps on read.
  validates :daily_section_count, numericality: { only_integer: true, in: DAILY_SECTION_COUNTS }, allow_nil: true,
                                  if: :daily_section_count_changed?

  normalizes :display_preferences, with: ->(values) { DisplayPreferences.sparse(values) }
  # nil, not {}, so where.not(api_keys: nil) finds exactly the accounts that can call a provider.
  normalizes :api_keys, with: ->(keys) { keys.presence }

  before_save { email.downcase! }

  # Only on preference changes, so unrelated saves can't refuse a mix save; the whole mix shares one version.
  before_save :bump_section_kind_preferences_version, if: :section_kind_preferences_changed?
  before_save :record_track_level_changes, if: -> { on_learning_track? && section_kind_levels_changed? }
  before_save :finish_learning_track, if: :on_learning_track?
  before_update :record_provider_on_unlabelled_reviews, if: -> { will_save_change_to_provider? && provider_in_database.present? }

  scope :active, -> { where(anonymized_at: nil) }

  enum :reminder_level, { none: 0, ready: 1, ready_and_nudges: 2 }, prefix: :reminders

  # Transport, not intent: reminder_level carries intent, which the job reads directly.
  def push_reminders_enabled? = !reminders_none?

  LOGIN_CODE_EXPIRY = 15.minutes
  LOGIN_CODE_MAX_ATTEMPTS = 5

  # Duration#inspect gives the humanized form ("15 minutes"), not a debug dump.
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

  # Under a row lock: unlocked, parallel posts of one code each redeem it (spec/models/login_code_concurrency_spec.rb).
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

  # Deletion anonymizes in place; never destroy, since dependent: :destroy would take the history with it.
  def anonymized?
    anonymized_at.present?
  end

  # Same-day only: an error from an earlier day is history, and the dashboard reports only today's.
  def clear_stale_generation_error!
    return unless last_generation_error_date == Date.current

    clear_generation_failure!
  end

  # Provider failures store kind and time and become words only when read (#generation_failure_message).
  NO_GENERATION_FAILURE = { last_generation_failure: nil, last_generation_failure_provider: nil,
                            last_generation_failed_at: nil, last_generation_retry_after: nil }.freeze

  def record_generation_failure!(error)
    update!(last_generation_error_date: Date.current, last_generation_error: nil,
            last_generation_failure: ProviderFailure.classify(error),
            last_generation_failure_provider: error.try(:provider) || provider,
            last_generation_failed_at: Time.current, last_generation_retry_after: error.try(:retry_after))
  end

  def record_generation_message!(message)
    update!(last_generation_error_date: Date.current, last_generation_error: message, **NO_GENERATION_FAILURE)
  end

  def clear_generation_failure!
    update!(last_generation_error_date: nil, last_generation_error: nil, **NO_GENERATION_FAILURE)
  end

  def generation_failed_today? = last_generation_error_date == Date.current

  # Names the provider the failed call went to, which the user may have switched away from since.
  def generation_failure_message(surface:, now: Time.current)
    return last_generation_error if last_generation_failure.blank?

    ProviderFailureText.new(last_generation_failure, provider: last_generation_failure_provider || provider,
                            surface: surface, failed_at: last_generation_failed_at, zone: effective_time_zone,
                            now: now, retry_after: last_generation_retry_after,
                            variant: ProviderFailureText.variant_for(self)).full
  end

  # Suppresses only unrequested generation; explicit /generate and /regenerate still run while paused.
  def paused_generation_at?
    paused_generation_at.present?
  end

  # Runs in the user's zone because it writes a date that must be the user's today; the row lock also beats a racing generation.
  def resume_generation!
    Time.use_zone(effective_time_zone) do
      with_lock do
        recovered = recover_held_set
        update!(paused_generation_at: nil)
        recovered
      end
    end
  end

  # The unlocked read is only a cost guard; an unsavable held row is logged, since a raise would 500 every paused dashboard load.
  def carry_held_set_forward!
    Time.use_zone(effective_time_zone) do
      return nil if held_exercise.nil?

      with_lock { recover_held_set }
    end
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.warn("Left held exercise in place for user #{id}: #{e.record.errors.full_messages.to_sentence}")
    nil
  end

  # with_lock makes it idempotent: a second call sees anonymized? and never overwrites anonymized_at.
  def anonymize!
    with_lock do
      return false if anonymized?

      # A home-screen install keeps its subscription after deletion, so the endpoints must go too.
      push_subscriptions.destroy_all
      clear_legacy_api_key

      update!(
        email:                  "deleted-user-#{id}@anonymized.local",
        name:                   "Deleted user",
        api_keys:               nil,
        login_code_sent_at:     nil,
        login_code_digest:      nil,
        login_code_attempts:    0,
        reminder_level:         :none,
        anonymized_at:          Time.current
      )
    end
    true
  end

  # ── API key ───────────────────────────────────────────────────────────────
  def api_key = api_keys&.dig(provider)

  def api_key_present?
    api_key.present?
  end

  # The nightly batch reads stored keys only, so a trial account generates only when it opens the dashboard.
  def provider_ready? = api_key_present? || trial_active?

  # A present trial_ends_at is the trial; there is no flag.
  def trial? = trial_ends_at.present?

  # Jobs queued before deletion still load the row, so an anonymized account must never reach the house key.
  def trial_active?(now: Time.current)
    trial? && !anonymized? && trial_ends_at > now && TrialMode.enabled? && HouseKeys.for(provider).present?
  end

  # A trial account with its own key is an own-key account, since ProviderCredential hands over that key first.
  def on_trial? = trial? && !api_key_present?

  def trial_ended? = on_trial? && !trial_active?

  # Under the row lock so it can't start twice; the trial runs from when the seat is taken, not from consent.
  def start_trial!(invite:, provider:, consented_at:, now: Time.current)
    with_lock do
      return false if api_key_present? || trial? || invite.nil?
      return false unless TrialMode.providers.include?(provider)
      return false unless invite.redeem!

      ends = now.in_time_zone(effective_time_zone).end_of_day + (invite.trial_days - 1).days
      update!(invite_code: invite, provider: provider, trial_started_at: now,
              trial_ends_at: ends, trial_consented_at: consented_at)
    end
    true
  end

  # In registry order, so Setup lists them the same way every time.
  def stored_providers
    AiProvider.keys & api_keys.to_h.keys
  end

  # Saving a key for a provider also selects it: the user just added it.
  def store_api_key(key, provider:)
    self.api_keys = api_keys.to_h.merge(provider => key)
    self.provider = provider
  end

  def on_learning_track? = learning_track == LearningTrack::ON

  def skill_level
    stored = super
    LEGACY_SKILL_LEVELS.fetch(stored, stored)
  end

  # Pre-track accounts were backfilled to "none"; the exercise check excludes the preview app's seeded account.
  def first_run?
    persisted? && learning_track.nil? && !daily_exercises.exists?
  end

  def learning_track_change_allowed?(value)
    case value
    when LearningTrack::ON then first_run?
    # A repeat leave is accepted: Setup's Leave control can outlive a track a mix save already ended.
    when LearningTrack::OFF then first_run? || on_learning_track? || learning_track == LearningTrack::OFF
    else false
    end
  end

  # Last N sessions by count, matching the "last 10 sessions" contract in the generation prompt.
  def recent_performance(limit: 10)
    recent_daily_responses(limit).map do |r|
      problem_set = r.daily_exercise&.problem_set || {}
      scenarios = ExerciseSection.keys.filter_map do |section|
        problem_set.dig(section, "scenario").presence
      end
      ai_ratings = r.answered_concept_tags.keys.index_with { |section| r.ai_rating_for(section) }.compact
      {
        date:              r.date.to_s,
        concepts:          r.concept_tags,
        scenarios:         scenarios,
        sections_answered: r.answered_sections.size,
        sections_total:    r.section_keys.size,
        self_ratings:      r.section_ratings,
        ai_ratings:        ai_ratings,
        answered_sections: r.answered_sections
      }
    end
  end

  # Excludes today by default, since it has had no chance to be answered; the forecast passes tomorrow.
  def recent_exercise_history(limit:, before: Date.current)
    daily_exercises
      .includes(:daily_response)
      .where(date: ...before)
      .order(date: :desc)
      .limit(limit)
      .map do |exercise|
        delivered = exercise.active_section_keys
        ExerciseHistoryEntry.new(
          section_keys:           delivered + exercise.dropped_sections,
          delivered_section_keys: delivered,
          answered:               exercise.daily_response&.answered_sections&.size,
          dropped:                exercise.dropped_sections.size
        )
      end
  end

  # Resolved per (concept, bucket) on the latest answered occurrence; drills lead, since callers truncate and order is priority.
  def concepts_needing_reinforcement(limit: 10, bucket: nil, exclude_buckets: [], hostable: nil)
    result   = drilled_reinforcement(bucket, exclude_buckets, hostable)
    resolved = result.to_h { |h| [ [ h[:concept], h[:bucket] ], true ] }

    recent_daily_responses(limit).each do |r|
      r.answered_concept_tags.each do |section, concept|
        next if concept.blank? || concept == "other"

        tag_bucket = ConceptBucket.for(section, r.daily_exercise&.language)
        next unless still_in_vocabulary?(concept, tag_bucket)
        next if resolved.key?([ concept, tag_bucket ])
        resolved[[ concept, tag_bucket ]] = true

        next if r.self_rating_for(section).nil? && r.ai_rating_for(section).nil? # out of scope

        next if r.self_rating_favorable?(section) && r.ai_rating_favorable?(section) # mastered

        next if bucket && tag_bucket != bucket
        next if exclude_buckets.include?(tag_bucket)

        tier = concept_masteries.find_by(concept: concept, language: tag_bucket)&.tier || "standard"
        next if tier == "paused"

        result << { concept: concept, bucket: tag_bucket, tier: tier }
      end
    end

    result
  end

  # Never-seen first, then least recently seen, so a large drilled group rotates instead of repeating its first few.
  def drilled_reinforcement(bucket, exclude_buckets, hostable)
    buckets = bucket ? [ bucket ] : ConceptBucket.slice_for(language) - exclude_buckets
    rows    = concept_masteries.drilling.in_buckets(buckets).where.not(tier: :paused)

    rows.select { |cm| hostable.nil? || hostable.call(cm.concept, cm.language) }
        .sort_by { |cm| drill_order(cm) }
        .map { |cm| { concept: cm.concept, bucket: cm.language, tier: cm.tier, drilled: true } }
  end
  private :drilled_reinforcement

  def drill_order(cm)
    seen = concept_exposure_index.fetch([ cm.concept, cm.language ], []).max
    [ seen ? 1 : 0, seen || Date.new, cm.drilled_at ]
  end
  private :drill_order

  # Unordered and uncapped, because DailyPlan ranks by overdue ratio, which a date order or cap would cut across (#93).
  def concepts_due_for_retention_check_in(buckets)
    concept_masteries.in_buckets(buckets).due_for_retention_check.to_a
  end

  # Excludes null intervals explicitly, since retention_interval_days clears whenever a check fails.
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

  # Memoized per instance so pages rendering many responses never query per section.
  def concept_exposure_index
    @concept_exposure_index ||= begin
      index = Hash.new { |hash, key| hash[key] = [] }
      daily_responses.where.not(submitted_at: nil).joins(:daily_exercise)
                     .pluck(:date, :concept_tags, "daily_exercises.language")
                     .each do |date, tags, language|
        (tags || {}).each do |section, concept|
          next if concept.blank? || concept == "other"
          bucket = ConceptBucket.for(section, language)
          # Union: several sections tagging a concept on one day count as one exposure, matching ConceptMastery.
          index[[ concept, bucket ]] |= [ date ]
        end
      end
      index
    end
  end

  def concept_exposure_count(concept, bucket, on_or_before:)
    concept_exposure_index.fetch([ concept, bucket ], []).count { |d| d <= on_or_before }
  end

  # "mixed" flips the latest prior exercise's language, excluding today's row so regeneration stays consistent.
  def language_for_today
    return language unless language == "mixed"

    last = daily_exercises.where.not(date: Date.current).order(date: :desc).first
    return "ruby_rails" unless last

    last.language == "ruby_rails" ? "javascript" : "ruby_rails"
  end

  # Walks back from today in the caller's zone; only a past weekday with an unsubmitted exercise breaks the streak.
  def current_streak
    submitted = daily_responses.where.not(submitted_at: nil).pluck(:date).to_set
    return 0 if submitted.empty?

    exercised = daily_exercises.pluck(:date).to_set
    earliest = submitted.min
    streak = 0
    day = Date.current
    while day >= earliest
      if day.on_weekend?
        # Weekends neither break nor count; folding this empty branch into the elsif would end streaks every Saturday.
      elsif submitted.include?(day)
        streak += 1
      elsif exercised.include?(day) && day != Date.current
        break
      end
      day -= 1
    end
    streak
  end

  # Blank until the browser detects it or the user sets it, so fall back to the team default.
  def effective_time_zone
    time_zone.presence || DEFAULT_TIME_ZONE
  end

  # ── Display ────────────────────────────────────────────────────────────────
  def provider_label = AiProvider.label(provider)

  private

  def clean_name
    self.name = UserText.clean(name, limit: UserText::MAX_NAME_LENGTH).strip
  end

  # Clears both regeneration columns: a stranded RegenerateExerciseJob would otherwise replace the moved set and draft.
  def carry_forward(held)
    # SAVEPOINT so a failed move rolls back alone and the pause still lifts.
    transaction(requires_new: true) do
      # Exercise, then response: RegenerateExerciseJob's lock order, so the two can't deadlock.
      held.lock!
      response = held.daily_response&.lock!
      # Re-checked under the lock, since a submit can commit after #held_exercise read it.
      next nil if response&.submitted?

      held.update!(date: Date.current, regenerated_at: nil, regenerating_since: nil)
      # The draft moves too, or #create would build a second response for the moved exercise.
      response&.update!(date: Date.current)
      clear_stale_generation_error!
      held
    end
  rescue ActiveRecord::RecordNotUnique
    nil
  rescue ActiveRecord::RecordInvalid => e
    raise unless e.record.errors[:date].present?
    nil
  end

  # Must run under #with_lock, in the user's zone: both callers hold both.
  def recover_held_set
    held = held_exercise
    return nil if held.nil? || daily_exercises.for_date.exists?

    carry_forward(held)
  end

  # Scoped to the pause, since a day abandoned before pausing was abandoned, not held; excludes today to avoid self-collision.
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

  # Reinforcing a concept that left the vocabulary wastes an entry and a retention slot; nil bucket is unreachable.
  def still_in_vocabulary?(concept, bucket)
    return true if bucket.nil?
    ConceptBucket.vocabulary_for(bucket).include?(concept)
  end

  # Shared so neither caller issues its own "last N sessions" query.
  def recent_daily_responses(limit)
    daily_responses.includes(:daily_exercise).order(date: :desc).limit(limit)
  end

  def time_zone_must_be_loadable
    return if time_zone.blank? # blank/nil = not yet detected; allowed
    errors.add(:time_zone, "is not a valid time zone") if Time.find_zone(time_zone).nil?
  end

  def bump_section_kind_preferences_version
    self.section_kind_preferences_version += 1
  end

  # Without a cutoff, the evidence for a move could immediately propose its opposite; dates use the user's day.
  def record_track_level_changes
    return if learning_track_changed?

    before = section_kind_levels_in_database || {}
    moved = section_kind_levels.select do |key, level|
      before[key] != level && LearningTrack::LEVELS.include?(level) && LearningTrack::LEVELS.include?(before[key])
    end
    return if moved.empty?

    through = Time.use_zone(effective_time_zone) { Date.current }.iso8601
    self.track_evidence_cutoffs = track_evidence_cutoffs.merge(
      moved.to_h { |key, level| [ key, { "level" => level, "through" => through } ] }
    )
  end

  def finish_learning_track
    return if section_kind_levels.values.include?(LearningTrack::START_LEVEL)

    self.learning_track = LearningTrack::OFF
  end

  def rotatable_keys
    ExerciseSection.rotatable.map(&:key)
  end

  def section_kind_weights_name_rotatable_kinds
    return errors.add(:section_kind_weights, "must be an object") unless section_kind_weights.is_a?(Hash)

    section_kind_weights.each do |key, value|
      errors.add(:section_kind_weights, "names an unknown section kind: #{key}") if rotatable_keys.exclude?(key)
      errors.add(:section_kind_weights, "has an unsupported weight for #{key}") if KindPreferences::MULTIPLIERS.exclude?(value)
    end
  end

  def excluded_section_kinds_name_rotatable_kinds
    return errors.add(:excluded_section_kinds, "must be a list") unless excluded_section_kinds.is_a?(Array)

    (excluded_section_kinds - rotatable_keys).each do |key|
      errors.add(:excluded_section_kinds, "names an unknown section kind: #{key}")
    end
  end

  def section_kind_preferences_changed?
    section_kind_weights_changed? || excluded_section_kinds_changed? ||
      section_kind_levels_changed? || locked_section_kinds_changed?
  end

  def section_kind_levels_name_section_kinds
    return errors.add(:section_kind_levels, "must be an object") unless section_kind_levels.is_a?(Hash)

    section_kind_levels.each do |key, value|
      errors.add(:section_kind_levels, "names an unknown section kind: #{key}") if ExerciseSection.keys.exclude?(key)
      errors.add(:section_kind_levels, "has an unsupported level for #{key}") if KindDifficulty::LEVELS.exclude?(value)
    end
  end

  def locked_section_kinds_name_section_kinds
    return errors.add(:locked_section_kinds, "must be a list") unless locked_section_kinds.is_a?(Array)

    (locked_section_kinds - ExerciseSection.keys).each do |key|
      errors.add(:locked_section_kinds, "names an unknown section kind: #{key}")
    end
  end

  # A CHECK constraint can't run subqueries; KindDifficulty#locked? makes a lock that slips past this inert.
  def locks_have_levels
    return unless locked_section_kinds.is_a?(Array) && section_kind_levels.is_a?(Hash)

    (locked_section_kinds - section_kind_levels.keys).each do |key|
      errors.add(:locked_section_kinds, "locks #{key} without a difficulty target")
    end
  end

  # The ignored api_key column still holds the copied key; remove this with the column.
  def clear_legacy_api_key
    self.class.where(id: id).update_all(api_key: nil)
  end

  # Labels old reviews before the provider changes, so they keep naming the provider that wrote them.
  def record_provider_on_unlabelled_reviews
    daily_responses.where(review_provider: nil).where.not(ai_review: [ nil, {} ])
                   .update_all(review_provider: provider_in_database)
  end

  def api_keys_name_providers
    return if api_keys.nil?
    return errors.add(:api_keys, "must be a map of provider to key") unless api_keys.is_a?(Hash)

    api_keys.each do |provider, key|
      errors.add(:api_keys, "names an unknown provider: #{provider}") unless AiProvider.keys.include?(provider)
      errors.add(:api_keys, "has a blank key for #{provider}") unless key.is_a?(String) && key.present?
    end
  end

  # Anonymized and trial accounts can name a provider while holding no keys.
  def provider_has_a_stored_key
    return unless api_keys.is_a?(Hash) && provider.present?

    errors.add(:provider, "has no stored key") unless api_keys.key?(provider)
  end

  def display_preferences_name_known_options
    DisplayPreferences.problems_with(display_preferences).each { |problem| errors.add(:display_preferences, problem) }
  end

  # Derived from the slot roster, so a future multi-kind slot needs no edit here.
  def every_slot_keeps_a_kind
    return unless excluded_section_kinds.is_a?(Array)

    ExerciseSection.slots.each do |slot, kinds|
      next if kinds.size <= 1
      next if kinds.any? { |kind| excluded_section_kinds.exclude?(kind.key) }

      errors.add(:excluded_section_kinds, "must leave at least one #{slot} section in rotation")
    end
  end
end
