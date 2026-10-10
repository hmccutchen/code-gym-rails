# The day's plan, decided before any provider is contacted, so scheduling rules are testable without a provider.
class DailyPlan
  Result = Data.define(:pattern, :third, :reinforcement, :due_checks, :established,
                        :fourth, :fourth_reinforcement, :fourth_due_checks, :fourth_established,
                        :code_review_mode, :code_review_source, :scenario_flavor,
                        :shared_concept, :coverage, :waiting_checks, :size) do
    # Size is the planned count before any coverage addition, so tomorrow compares against what was planned.
    def notes
      { "size" => size&.count, "size_reason" => size&.reason&.to_s,
        "coverage" => coverage&.kind&.key, "coverage_reason" => coverage&.reason&.to_s,
        "shared_concept" => shared_concept }.compact
    end
  end

  # One roll across all three modes, so the mode is decided and recorded here rather than left to the prompt.
  CODE_REVIEW_MODE_WEIGHTS = {
    application_code: 0.34, test_file: 0.33, schema_review: 0.33
  }.freeze

  # Rolled once per day so the flavor is decided here; a split stated in the prompt would decide nothing.
  SCENARIO_FLAVOR_WEIGHTS = { everyday: 0.5, general: 0.5 }.freeze

  # Derived from ConceptBucket; a fourth kind without a special bucket resolves to nil and fails the fetch below.
  FOURTH_BUCKET_FOR = ExerciseSection.fourths
    .to_h { |kind| [ kind.key.to_sym, ConceptBucket.for(kind.key, nil) ] }
    .freeze

  # No code_review/pattern/third section can host these buckets, so they never enter the non-fourth pool.
  FOURTH_BUCKETS = FOURTH_BUCKET_FOR.values.freeze

  # Everything competing for the fourth slot is sized against this, so one section is never asked for two concepts.
  FOURTH_SLOT_CAPACITY = 1

  # fourth_track's early return when no fourth section was chosen today.
  NO_FOURTH_TRACK = { fourth: nil, fourth_reinforcement: [], fourth_due_checks: [], fourth_established: [] }.freeze

  # Concepts are chosen here so the caller can compare what was offered with what was used (AiService#log_retention).
  def self.for(user, language:)
    history          = user.recent_exercise_history(limit: SectionRotation::LOOKBACK)
    size             = size_for(user, history)
    preferences      = KindPreferences.for(user)
    rotation         = SectionRotation.for(history, count: size.count, preferences: preferences)
    code_review_mode = WeightedRoll.pick(CODE_REVIEW_MODE_WEIGHTS)
    hosts            = DayHosts.new(language, mode: code_review_mode)
    due              = user.concepts_due_for_retention_check_in(due_buckets(user, language))
    tracks           = concept_tracks(user, language, rotation, due: due, hosts: hosts)
    coverage, rotation, tracks = with_coverage(coverage_for(user, size, preferences, tracks.fetch(:waiting_checks), hosts),
                                               rotation, tracks, user, language, due: due, hosts: hosts)

    Result.new(pattern: rotation.fetch(:pattern), third: rotation.fetch(:third), **tracks, coverage: coverage, size: size,
               code_review_mode: code_review_mode,
               code_review_source: code_review_source_for(user, language, code_review_mode),
               scenario_flavor: WeightedRoll.pick(SCENARIO_FLAVOR_WEIGHTS))
  end

  # Public so the dashboard's forecast composes the size the same way; CompetencyGate.for is costly, so call it once.
  def self.size_for(user, history)
    DaySize.for(setting: user.daily_section_count, completion: SectionCount.for(history), gate: CompetencyGate.for(user))
  end

  # The generated language can differ from the setting when a regeneration keeps the stored exercise's language.
  def self.due_buckets(user, language)
    ConceptBucket.slice_for(user.language) | [ language ]
  end
  private_class_method :due_buckets

  # Computed again when the coverage exception adds a kind, so the added section can take its check.
  def self.concept_tracks(user, language, rotation, due:, hosts:)
    kinds  = ExerciseSection.for_plan(**rotation)
    tracks = main_track(user, language, kinds: kinds, hosts: hosts, due: due).merge(fourth_track(user, rotation.fetch(:fourth), due: due))

    tracks.merge(waiting_checks: waiting_checks(tracks, due, kinds: kinds, hosts: hosts))
  end
  private_class_method :concept_tracks

  # When reinforcement outranks the check the kind was added for, the addition is given up and the day stays at two.
  def self.with_coverage(coverage, rotation, tracks, user, language, due:, hosts:)
    return [ nil, rotation, tracks ] unless coverage

    added_rotation = rotation.merge(ExerciseSection.slot_for(coverage.kind) => coverage.kind.key.to_sym)
    added_tracks   = concept_tracks(user, language, added_rotation, due: due, hosts: hosts)
    return [ nil, rotation, tracks ] unless check_landed?(coverage, added_tracks)

    [ coverage, added_rotation, added_tracks ]
  end
  private_class_method :with_coverage

  def self.check_landed?(coverage, tracks)
    return true unless coverage.check

    (tracks[:due_checks] + tracks[:fourth_due_checks])
      .any? { |cm| cm.concept == coverage.check[:concept] && cm.language == coverage.check[:bucket] }
  end
  private_class_method :check_landed?

  # Cheapest check first: only a day that passes the setting, count and cap loads the gaps.
  def self.coverage_for(user, size, preferences, waiting, hosts)
    day = { count: size.count, fixed: size.setting, brake: size.brake? }
    return nil unless CoverageException.applies_to_day?(**day)

    recent = CoverageException::History.recent_coverage_dates(user)
    return nil if CoverageException.capped?(recent, Date.current)

    CoverageException.for(today: Date.current, **day, history: CoverageException::History.for(user, coverage_dates: recent),
                          checks: waiting, preferences: preferences, hosts: hosts)
  end
  private_class_method :coverage_for

  # A concept reinforcement already carries is being worked, so it is not listed as waiting.
  def self.waiting_checks(tracks, due, kinds:, hosts:)
    taken = claimed_concepts(tracks[:reinforcement] + tracks[:fourth_reinforcement],
                             tracks[:due_checks] + tracks[:fourth_due_checks])

    due.reject { |cm| taken.include?([ cm.concept, cm.language ]) }
       .sort_by { |cm| -overdue_ratio(cm) }
       .map do |cm|
         reason = hosts.hosts(kinds, cm.concept, cm.language).any? ? :no_slot : :no_host
         { bucket: cm.language, concept: cm.concept, overdue_ratio: overdue_ratio(cm), reason: reason }
       end
  end
  private_class_method :waiting_checks

  # Truncated to today's hosts because the prompt demands every listed concept; the shared concept is decided last.
  def self.main_track(user, language, kinds:, hosts:, due:)
    hostable      = hostable_buckets(language, kinds: kinds)
    reinforcement = user.concepts_needing_reinforcement(exclude_buckets: FOURTH_BUCKETS,
                                                        hostable: drill_host_test(kinds: kinds, hosts: hosts))
                        .select { |h| hostable.include?(h[:bucket]) }
    # Deliberately approximate: fixed kinds host fewer concepts on some days, and placement is advisory anyway.
    capacity      = kinds.count { |kind| !kind.fourth? }
    reinforcement = share_hosts(reinforcement, capacity)
    slots         = capacity - reinforcement.size
    slots         = 1 if slots.zero? && overdue_retention_check_pending?(due, kinds: kinds, hosts: hosts, reinforcement: reinforcement)
    reinforcement = reinforcement.first(capacity - slots)
    due_checks    = retention_checks_for(due, kinds: kinds, hosts: hosts, slots: slots, reinforcement: reinforcement)
    shared        = SharedConcept.pick(reinforcement, due_checks, hosts, kinds: kinds)

    { reinforcement: reinforcement, due_checks: due_checks, shared_concept: shared&.fetch(:concept),
      established: established_concepts_for(user, language, kinds: kinds,
                                            reinforcement: reinforcement, due_checks: due_checks) }
  end
  private_class_method :main_track

  # A second roll inside the mode, so CODE_REVIEW_MODE_WEIGHTS' three-way split stays exact.
  def self.code_review_source_for(user, language, mode)
    return nil unless language == RealSource::LANGUAGE && RealSource.pool(mode).any?
    return nil unless WeightedRoll.pick(RealSource::WEIGHTS) == :real

    RealSource.pick(mode, last_seen: RealSource.last_seen_for(user))
  end
  private_class_method :code_review_source_for

  # When evidence-driven reinforcement waits, drills keep all but one host so a group drill cannot starve it.
  def self.share_hosts(reinforcement, capacity)
    drilled, evidence = reinforcement.partition { |h| h[:drilled] }
    return reinforcement.first(capacity) if evidence.empty?

    (drilled.first([ capacity - 1, 1 ].max) + evidence).first(capacity)
  end
  private_class_method :share_hosts

  # Bucket-level hosting is not enough: an application_code code_review cannot tag a data-modeling concept.
  def self.drill_host_test(kinds:, hosts:)
    candidates = kinds.reject(&:fourth?)

    ->(concept, bucket) { hosts.hosts(candidates, concept, bucket).any? }
  end
  private_class_method :drill_host_test

  # Kept separate from the non-fourth track because the two vocabularies can never mix.
  def self.fourth_track(user, fourth, due:)
    return NO_FOURTH_TRACK if fourth.nil?

    bucket = FOURTH_BUCKET_FOR.fetch(fourth)
    # Truncated before anything reads it: the section can carry only one concept.
    reinforcement = user.concepts_needing_reinforcement(bucket: bucket).first(FOURTH_SLOT_CAPACITY)
    # An overdue check takes the slot outright; sharing it would put two exclusive concepts in one prompt.
    reinforcement = [] if reinforcement.any? && overdue_retention_check_pending_for_bucket?(user, bucket, reinforcement: reinforcement)
    due_checks    = retention_checks_for_bucket(due, bucket, slots: FOURTH_SLOT_CAPACITY - reinforcement.size,
                                                reinforcement: reinforcement)

    { fourth: fourth, fourth_reinforcement: reinforcement, fourth_due_checks: due_checks,
      fourth_established: established_concepts_for_bucket(user, bucket, reinforcement: reinforcement,
                                                          due_checks: due_checks) }
  end
  private_class_method :fourth_track

  def self.retention_checks_for_bucket(due, bucket, slots:, reinforcement: [])
    return [] if slots.zero?

    unclaimed_by(reinforcement, due.select { |cm| cm.language == bucket })
      .sort_by { |cm| -(overdue_ratio(cm)) }
      .first(slots)
  end
  private_class_method :retention_checks_for_bucket

  # Single-bucket analog of established_concepts_for.
  def self.established_concepts_for_bucket(user, bucket, reinforcement:, due_checks:)
    claimed = claimed_concepts(reinforcement, due_checks)

    established_in_buckets(user, [ bucket ]).reject { |cm| claimed.include?([ cm.concept, cm.language ]) }
  end
  private_class_method :established_concepts_for_bucket

  # Required: a small fourth vocabulary nearly always has reinforcement, which would otherwise starve retention.
  def self.overdue_retention_check_pending_for_bucket?(user, bucket, reinforcement: [])
    claimed_here = claimed_concepts(reinforcement).filter_map { |concept, claimed_bucket| concept if claimed_bucket == bucket }

    user.concepts_overdue_for_retention_check(bucket: bucket).where.not(concept: claimed_here).exists?
  end
  private_class_method :overdue_retention_check_pending_for_bucket?

  # Shared by both retention callers so reserving a slot and filling it read the same eligibility rule.
  def self.hostable_buckets(language, kinds:)
    buckets = [ language ]
    buckets << "architecture" if kinds.include?(ExerciseSection::Architecture)
    buckets
  end
  private_class_method :hostable_buckets

  # Ranked by overdue ratio, not raw due date, and truncated only after ranking, to match the reservation test.
  def self.retention_checks_for(due, kinds:, hosts:, slots:, reinforcement: [])
    return [] if slots.zero?

    unclaimed_by(reinforcement, hostable_checks(due, kinds: kinds, hosts: hosts))
      .sort_by { |cm| -(overdue_ratio(cm)) }.first(slots)
  end
  private_class_method :retention_checks_for

  def self.hostable_checks(due, kinds:, hosts:)
    candidates = kinds.reject(&:fourth?)
    due.select { |cm| hosts.hosts(candidates, cm.concept, cm.language).any? }
  end
  private_class_method :hostable_checks

  # A drilled concept's due check stands down so one prompt never names it under two instructions.
  def self.unclaimed_by(reinforcement, due_checks)
    claimed = claimed_concepts(reinforcement)
    due_checks.reject { |cm| claimed.include?([ cm.concept, cm.language ]) }
  end
  private_class_method :unclaimed_by

  # Matched on the (concept, bucket) pair, never the name alone (#190).
  def self.claimed_concepts(reinforcement, due_checks = [])
    reinforcement.map { |h| [ h[:concept], h[:bucket] ] } + due_checks.map { |cm| [ cm.concept, cm.language ] }
  end
  private_class_method :claimed_concepts

  # A nil or zero interval sorts last rather than raising.
  def self.overdue_ratio(cm)
    return -Float::INFINITY if cm.retention_interval_days.to_i <= 0
    (Date.current - cm.next_retention_check_on).to_f / cm.retention_interval_days
  end
  private_class_method :overdue_ratio

  # Reinforcement and due checks carry stronger annotations, so anything they claim is excluded.
  def self.established_concepts_for(user, language, kinds:, reinforcement:, due_checks:)
    claimed = claimed_concepts(reinforcement, due_checks)

    established_in_buckets(user, hostable_buckets(language, kinds: kinds))
      .reject { |cm| claimed.include?([ cm.concept, cm.language ]) }
  end
  private_class_method :established_concepts_for

  # One condition per bucket, OR-ed, so a language concept cannot qualify by matching the architecture list.
  def self.established_in_buckets(user, buckets)
    buckets.map { |bucket| established_in_bucket(user, bucket) }.reduce(:or)
  end
  private_class_method :established_in_buckets

  def self.established_in_bucket(user, bucket)
    user.concept_masteries
      .in_bucket(bucket)
      .where(tier: :standard)
      .where("retention_interval_days > ?", ConceptMastery::RETENTION_INITIAL_INTERVAL_DAYS)
  end
  private_class_method :established_in_bucket

  # Reads the same hostable list retention_checks_for fills from, so no slot is reserved for an unhostable check.
  def self.overdue_retention_check_pending?(due, kinds:, hosts:, reinforcement: [])
    unclaimed_by(reinforcement, hostable_checks(due, kinds: kinds, hosts: hosts))
      .any? { |cm| overdue_ratio(cm) >= ConceptMastery::RETENTION_OVERDUE_THRESHOLD_MULTIPLIER }
  end
  private_class_method :overdue_retention_check_pending?
end
