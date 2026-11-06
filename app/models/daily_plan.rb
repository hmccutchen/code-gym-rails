# Design notes: docs/code-notes/app/models/daily_plan.md
class DailyPlan
  Result = Data.define(:daily_kinds, :rotation, :reinforcement, :due_checks, :established,
                        :fourth_reinforcement, :fourth_due_checks, :fourth_established,
                        :code_review_mode, :code_review_source, :code_review_files, :code_review_gotcha, :featured_concept, :scenario_flavor,
                        :shared_concept, :coverage, :waiting_checks, :size, :selected_kinds, :practice_schedule, :assignments) do
    def initialize(**attributes)
      super(**{ selected_kinds: nil, practice_schedule: nil, assignments: {} }.merge(attributes))
    end

    def notes(kind_rungs: nil)
      { "daily_kinds" => daily_kinds.map(&:key), "size" => size&.count, "size_reason" => size&.reason&.to_s,
        "brake" => (true if size&.brake?), "coverage" => coverage&.kind&.key, "coverage_reason" => coverage&.reason&.to_s,
        "shared_concept" => shared_concept, "bug_hunt" => code_review_gotcha&.id, "kind_rungs" => kind_rungs,
        "practice_schedule" => practice_schedule }.compact
    end

    def kinds = selected_kinds || ExerciseSection.for_plan(daily: daily_kinds, rotation: rotation)

    def fourth = kinds.find(&:fourth?)&.key&.to_sym

    def judge_retries(kind) = daily_kinds.include?(kind) ? DAILY_JUDGE_RETRIES : ROTATED_JUDGE_RETRIES
  end

  DAILY_JUDGE_RETRIES   = 2
  ROTATED_JUDGE_RETRIES = 1

  CODE_REVIEW_MODE_WEIGHTS = {
    application_code: 0.30, test_file: 0.29, schema_review: 0.41
  }.freeze

  WEEKEND_CODE_REVIEW_MODE_WEIGHTS = { ExerciseSection::CodeReview::BugHunt::MODE => 1.0 }.freeze

  CODE_REVIEW_MODES = (CODE_REVIEW_MODE_WEIGHTS.keys + WEEKEND_CODE_REVIEW_MODE_WEIGHTS.keys).freeze

  CODE_REVIEW_FILE_WEIGHTS = { single: 0.75, multi: 0.25 }.freeze

  SCENARIO_FLAVOR_WEIGHTS = { everyday: 0.5, general: 0.5 }.freeze

  # Derived from ConceptBucket: a fourth kind needs a special bucket there, or its entry here is nil.
  FOURTH_BUCKET_FOR = ExerciseSection.fourths
    .to_h { |kind| [ kind.key.to_sym, ConceptBucket.for(kind.key, nil) ] }
    .freeze

  FOURTH_BUCKETS = FOURTH_BUCKET_FOR.values.freeze

  FOURTH_SLOT_CAPACITY = 1

  NO_FOURTH_TRACK = { fourth_reinforcement: [], fourth_due_checks: [], fourth_established: [] }.freeze

  def self.for(user, language:, featured_concept: nil, weekend: Date.current.on_weekend?, schedule_context: nil) # rubocop:disable Metrics/MethodLength
    weekend = schedule_context.fetch(:date).on_weekend? if schedule_context
    history          = user.recent_exercise_history(limit: SectionRotation::LOOKBACK)
    size             = schedule_context ? size_for(user, before: schedule_context.fetch(:date)) : size_for(user)
    preferences      = KindPreferences.for(user)
    daily            = DailyKinds.for(user)
    rotation         = SectionRotation.for(history, count: size.count, preferences: preferences, daily: daily)
    code_review_mode = WeightedRoll.pick(weekend ? WEEKEND_CODE_REVIEW_MODE_WEIGHTS : CODE_REVIEW_MODE_WEIGHTS)
    trap             = code_review_gotcha_for(user, language, code_review_mode, featured_concept)
    hosts_for        = lambda do |day_rotation, featured = featured_concept|
      DayHosts.new(language, mode: code_review_mode, gotcha: day_gotcha(trap, daily, day_rotation), featured_concept: featured)
    end
    unfeatured_for   = ->(day_rotation) { hosts_for.call(day_rotation, nil) if featured_concept }
    hosts            = hosts_for.call(rotation)
    due              = user.concepts_due_for_retention_check_in(due_buckets(user, language))
    if schedule_context&.fetch(:active)
      selection, tracks = protected_tracks(user, language, daily, size, preferences, history, due, hosts, schedule_context)
      rotation = selection.rotation
      coverage = nil
    else
      tracks = concept_tracks(user, language, daily, rotation, due: due, hosts: hosts, unfeatured: unfeatured_for.call(rotation))
      coverage, rotation, tracks = with_coverage(coverage_for(user, size, preferences, daily, tracks.fetch(:waiting_checks), hosts),
                                               daily, rotation, tracks, user, language, due: due, hosts_for: hosts_for,
                                               unfeatured_for: unfeatured_for)
    end

    source = code_review_source_for(user, language, code_review_mode)
    single = source || !ExerciseSection::CodeReview.multi_file_mode?(code_review_mode)

    Result.new(daily_kinds: daily, rotation: rotation, **tracks, coverage: coverage, size: size,
               selected_kinds: selection&.kinds, practice_schedule: selection&.notes, assignments: selection&.assignments || {},
               code_review_mode: code_review_mode, code_review_source: source,
               code_review_files: single ? :single : WeightedRoll.pick(CODE_REVIEW_FILE_WEIGHTS),
               code_review_gotcha: day_gotcha(trap, daily, rotation), featured_concept: featured_concept,
               scenario_flavor: WeightedRoll.pick(SCENARIO_FLAVOR_WEIGHTS))
  end

  def self.protected_tracks(user, language, daily, size, preferences, history, due, hosts, context)
    candidates = user.concepts_needing_reinforcement(hostable: ->(concept, bucket) { hosts.hosts(ExerciseSection.all, concept, bucket).any? })
    drilled, ordinary = candidates.partition { |entry| entry[:drilled] }
    evidence = context.fetch(:evidence).merge(reinforcement: ordinary)
    checks = due.reject(&:tier_paused?).map { |row| { concept: row.concept, bucket: row.language, overdue_ratio: overdue_ratio(row) } }
    selection = PracticeSchedule.plan(context: context.fetch(:note), count: size.count, setting: size.setting, daily: daily,
      preferences: preferences, evidence: evidence, hosts: hosts, rotation_history: history, due: checks, drills: drilled,
      replacing: context[:replacing_id].present?, regular: DailyKinds.pair(user))
    assigned = selection.assignments.values
    selected_checks = due.select { |row| assigned.any? { |entry| entry[:reason] == "retention" && entry.values_at(:concept, :bucket) == [ row.concept, row.language ] } }
    reinforcement = assigned.reject { |entry| entry[:reason] == "retention" }.map do |entry|
      entry.slice(:concept, :bucket, :kind).merge(tier: entry[:mode] == "simplified" ? "reduced" : "standard", drilled: entry[:reason] == "drill")
    end
    fourth, main = reinforcement.partition { |entry| ExerciseSection.for(entry.fetch(:kind)).fourth? }
    fourth_checks, main_checks = selected_checks.partition do |row|
      assigned.any? { |entry| entry.values_at(:concept, :bucket) == [ row.concept, row.language ] && ExerciseSection.for(entry.fetch(:kind)).fourth? }
    end
    tracks = { reinforcement: main, due_checks: main_checks, established: [], fourth_reinforcement: fourth,
      fourth_due_checks: fourth_checks, fourth_established: [], shared_concept: shared_assignment(selection, daily) }
    tracks[:waiting_checks] = waiting_checks(tracks, due, kinds: selection.kinds, hosts: hosts, unfeatured: nil)
    [ selection, tracks ]
  end
  private_class_method :protected_tracks

  def self.shared_assignment(selection, daily)
    pair = DailyKinds.shared_pair(daily)
    return if pair.empty?

    entries = pair.map { |kind| selection.assignments[kind.key] }
    return unless entries.all? { |entry| entry && entry[:reason] == "reinforcement" } &&
      entries.map { |entry| entry.values_at(:concept, :bucket) }.uniq.one?

    entries.first.fetch(:concept)
  end
  private_class_method :shared_assignment

  def self.code_review_gotcha_for(user, language, mode, featured_concept)
    return nil unless ExerciseSection::CodeReview::BugHunt.mode?(mode)

    BugHuntGotchas.pick(language, last_seen: BugHuntGotchas.last_seen_for(user), featured_concept: featured_concept)
  end
  private_class_method :code_review_gotcha_for

  def self.day_gotcha(trap, daily, rotation)
    trap if code_review_day?(daily, rotation)
  end
  private_class_method :day_gotcha

  def self.code_review_day?(daily, rotation)
    ExerciseSection.for_plan(daily: daily, rotation: rotation).include?(ExerciseSection::CodeReview)
  end
  private_class_method :code_review_day?

  def self.size_for(user, before: Date.current)
    return DaySize.for(setting: user.daily_section_count) if user.daily_section_count

    DaySize.for(setting: nil, gate: CompetencyGate.for(user, before: before))
  end

  def self.due_buckets(user, language)
    ConceptBucket.slice_for(user.language) | [ language ]
  end
  private_class_method :due_buckets

  def self.concept_tracks(user, language, daily, rotation, due:, hosts:, unfeatured:)
    kinds  = ExerciseSection.for_plan(daily: daily, rotation: rotation)
    tracks = main_track(user, language, kinds: kinds, daily: daily, hosts: hosts, due: due)
             .merge(fourth_track(user, kinds.find(&:fourth?), due: due, hosts: hosts))

    tracks.merge(waiting_checks: waiting_checks(tracks, due, kinds: kinds, hosts: hosts, unfeatured: unfeatured))
  end
  private_class_method :concept_tracks

  def self.with_coverage(coverage, daily, rotation, tracks, user, language, due:, hosts_for:, unfeatured_for:)
    return [ nil, rotation, tracks ] unless coverage

    added_rotation = rotation.merge(ExerciseSection.slot_for(coverage.kind, daily: daily) => coverage.kind.key.to_sym)
    added_tracks   = concept_tracks(user, language, daily, added_rotation, due: due, hosts: hosts_for.call(added_rotation),
                                    unfeatured: unfeatured_for.call(added_rotation))
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

  def self.coverage_for(user, size, preferences, daily, waiting, hosts)
    day = { count: size.count, fixed: size.setting, brake: size.brake? }
    return nil unless CoverageException.applies_to_day?(**day)

    recent = CoverageException::History.recent_coverage_dates(user)
    return nil if CoverageException.capped?(recent, Date.current)

    CoverageException.for(today: Date.current, **day, history: CoverageException::History.for(user, coverage_dates: recent),
                          checks: waiting, preferences: preferences, hosts: hosts, daily: daily)
  end
  private_class_method :coverage_for

  def self.waiting_checks(tracks, due, kinds:, hosts:, unfeatured:)
    taken = claimed_concepts(tracks[:reinforcement] + tracks[:fourth_reinforcement],
                             tracks[:due_checks] + tracks[:fourth_due_checks])

    due.reject { |cm| taken.include?([ cm.concept, cm.language ]) }
       .sort_by { |cm| -overdue_ratio(cm) }
       .map do |cm|
         reason = hosts.hosts(kinds, cm.concept, cm.language).any? ? :no_slot : :no_host
         held   = reason == :no_host && unfeatured&.hosts(kinds, cm.concept, cm.language)&.any?
         { bucket: cm.language, concept: cm.concept, overdue_ratio: overdue_ratio(cm), reason: reason, held_by_featured: (true if held) }.compact
       end
  end
  private_class_method :waiting_checks

  def self.main_track(user, language, kinds:, daily:, hosts:, due:)
    reinforcement = user.concepts_needing_reinforcement(exclude_buckets: FOURTH_BUCKETS,
                                                        hostable: host_test(kinds: kinds, hosts: hosts))
    capacity      = kinds.count { |kind| !kind.fourth? && hosts.planning_host?(kind) }
    reinforcement = share_hosts(reinforcement, capacity)
    slots         = capacity - reinforcement.size
    slots         = 1 if slots.zero? && overdue_retention_check_pending?(due, kinds: kinds, hosts: hosts, reinforcement: reinforcement)
    reinforcement = reinforcement.first(capacity - slots)
    due_checks    = retention_checks_for(due, kinds: kinds, hosts: hosts, slots: slots, reinforcement: reinforcement)
    shared        = SharedConcept.pick(reinforcement, due_checks, hosts, kinds: kinds, daily: DailyKinds.shared_pair(daily))

    { reinforcement: reinforcement, due_checks: due_checks, shared_concept: shared&.fetch(:concept),
      established: established_concepts_for(user, language, kinds: kinds,
                                            reinforcement: reinforcement, due_checks: due_checks) }
  end
  private_class_method :main_track

  def self.code_review_source_for(user, language, mode)
    return nil unless language == RealSource::LANGUAGE && RealSource.pool(mode).any?
    return nil unless WeightedRoll.pick(RealSource::WEIGHTS) == :real

    RealSource.pick(mode, last_seen: RealSource.last_seen_for(user))
  end
  private_class_method :code_review_source_for

  def self.share_hosts(reinforcement, capacity)
    drilled, evidence = reinforcement.partition { |h| h[:drilled] }
    return reinforcement.first(capacity) if evidence.empty?

    (drilled.first([ capacity - 1, 1 ].max) + evidence).first(capacity)
  end
  private_class_method :share_hosts

  def self.host_test(kinds:, hosts:)
    candidates = kinds.reject(&:fourth?)

    ->(concept, bucket) { hosts.hosts(candidates, concept, bucket).any? }
  end
  private_class_method :host_test

  def self.fourth_track(user, kind, due:, hosts:)
    return NO_FOURTH_TRACK if kind.nil?

    bucket        = FOURTH_BUCKET_FOR.fetch(kind.key.to_sym)
    hostable      = ->(concept, concept_bucket) { hosts.can_tag?(kind, concept, concept_bucket) }
    reinforcement = user.concepts_needing_reinforcement(bucket: bucket, hostable: hostable).first(FOURTH_SLOT_CAPACITY)
    reinforcement = [] if reinforcement.any? && overdue_retention_check_pending_for_bucket?(user, bucket, reinforcement: reinforcement, hostable: hostable)
    due_checks    = retention_checks_for_bucket(due.select { |cm| hostable.call(cm.concept, cm.language) }, bucket,
                                                slots: FOURTH_SLOT_CAPACITY - reinforcement.size, reinforcement: reinforcement)
    established   = established_concepts_for_bucket(user, bucket, reinforcement: reinforcement, due_checks: due_checks)

    { fourth_reinforcement: reinforcement, fourth_due_checks: due_checks,
      fourth_established: established.select { |cm| hostable.call(cm.concept, cm.language) } }
  end
  private_class_method :fourth_track

  def self.retention_checks_for_bucket(due, bucket, slots:, reinforcement: [])
    return [] if slots.zero?

    unclaimed_by(reinforcement, due.select { |cm| cm.language == bucket })
      .sort_by { |cm| -(overdue_ratio(cm)) }
      .first(slots)
  end
  private_class_method :retention_checks_for_bucket

  def self.established_concepts_for_bucket(user, bucket, reinforcement:, due_checks:)
    claimed = claimed_concepts(reinforcement, due_checks)

    established_in_buckets(user, [ bucket ]).reject { |cm| claimed.include?([ cm.concept, cm.language ]) }
  end
  private_class_method :established_concepts_for_bucket

  # Required: a small fourth vocabulary nearly always has reinforcement, which would otherwise starve retention.
  def self.overdue_retention_check_pending_for_bucket?(user, bucket, hostable:, reinforcement: [])
    claimed_here = claimed_concepts(reinforcement).filter_map { |concept, claimed_bucket| concept if claimed_bucket == bucket }

    user.concepts_overdue_for_retention_check(bucket: bucket).where.not(concept: claimed_here).any? { |cm| hostable.call(cm.concept, bucket) }
  end
  private_class_method :overdue_retention_check_pending_for_bucket?

  def self.hostable_buckets(language, kinds:)
    kinds.reject(&:fourth?).map { |kind| ConceptBucket.for(kind.key, language) }.uniq
  end
  private_class_method :hostable_buckets

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

  def self.established_concepts_for(user, language, kinds:, reinforcement:, due_checks:)
    claimed = claimed_concepts(reinforcement, due_checks)

    established_in_buckets(user, hostable_buckets(language, kinds: kinds))
      .reject { |cm| claimed.include?([ cm.concept, cm.language ]) }
  end
  private_class_method :established_concepts_for

  def self.established_in_buckets(user, buckets)
    buckets.map { |bucket| established_in_bucket(user, bucket) }.reduce(:or) || user.concept_masteries.none
  end
  private_class_method :established_in_buckets

  def self.established_in_bucket(user, bucket)
    user.concept_masteries
      .in_bucket(bucket)
      .where(tier: :standard)
      .where("retention_interval_days > ?", ConceptMastery::RETENTION_INITIAL_INTERVAL_DAYS)
  end
  private_class_method :established_in_bucket

  def self.overdue_retention_check_pending?(due, kinds:, hosts:, reinforcement: [])
    unclaimed_by(reinforcement, hostable_checks(due, kinds: kinds, hosts: hosts))
      .any? { |cm| overdue_ratio(cm) >= ConceptMastery::RETENTION_OVERDUE_THRESHOLD_MULTIPLIER }
  end
  private_class_method :overdue_retention_check_pending?
end
