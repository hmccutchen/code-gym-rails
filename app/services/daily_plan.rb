# The day's exercise plan, decided before any provider is contacted: which third
# section the set gets, which concepts are due for reinforcement, and which
# mastered concepts get a retention check. Pure decision — no prompt, no HTTP —
# so the scheduling rules can be exercised directly instead of only through a
# stubbed provider call.
#
# AiService#generate_exercise asks for a plan and renders it; nothing here knows
# what a prompt looks like.
#
# DailyPlan itself is a plain class of scheduling logic, not a value object —
# `.for` is the only public entry point and everything below it is a step
# toward building one. Result is the value it hands back.
class DailyPlan
  Result = Data.define(:pattern, :third, :reinforcement, :due_checks, :established,
                        :fourth, :fourth_reinforcement, :fourth_due_checks, :fourth_established,
                        :code_review_mode, :code_review_source, :scenario_flavor,
                        :shared_concept, :coverage, :waiting_checks, :size) do
    # What daily_exercises.plan_notes stores for the day this plan produced.
    # The size is the planned count before any coverage addition, so the next
    # day compares against what was planned rather than what was delivered.
    def notes
      { "size" => size&.count, "size_reason" => size&.reason&.to_s,
        "coverage" => coverage&.kind&.key, "coverage_reason" => coverage&.reason&.to_s,
        "shared_concept" => shared_concept }.compact
    end
  end

  # Which content mode code_review takes. Equal thirds, as close as float
  # weights get — application_code keeps a 1% edge rather than the split
  # pretending to be exact.
  #
  # One roll across all three modes, not a probability per mode: the previous
  # arrangement asked the model for "roughly 1 in 4" test-file days in the
  # prompt itself, so nothing decided or recorded the mode and a second
  # "occasional" mode would have compounded with the first unpredictably.
  CODE_REVIEW_MODE_WEIGHTS = {
    application_code: 0.34, test_file: 0.33, schema_review: 0.33
  }.freeze

  # Which scenario pool today's prompt offers (AiService::SCENARIO_POOLS).
  # Leaned hard toward the setting the engineer asked for, with a floor for
  # the general pool rather than none: an exclusive pool relocates the
  # staleness this exists to fix into a smaller fixed pool, and a familiar
  # setting starts to predict the bug. Rolled once per day, not per section,
  # the same shape as CODE_REVIEW_MODE_WEIGHTS and for the same reason a
  # prompt-stated "roughly 7 in 10" was rejected: nothing would decide or
  # record it. Not gated on language or kinds — every day has a scenario.
  SCENARIO_FLAVOR_WEIGHTS = { game_and_animation: 0.7, general: 0.3 }.freeze

  # A beginner trades the job-adjacent pool for an everyday one: webhooks,
  # tenants and invoice runs assume someone already works in software, which
  # a career changer does not. The game pool stays as the second setting, so
  # a beginner still has two pools to vary between. Keyed on skill level, a
  # difficulty setting, because generation never reads learning-track state;
  # joining the junior track sets beginner.
  SCENARIO_FLAVOR_WEIGHTS_BY_SKILL_LEVEL = {
    "beginner" => { everyday: 0.7, game_and_animation: 0.3 }.freeze
  }.freeze

  # Each fourth kind's own ConceptBucket name — see ConceptBucket. One bucket
  # per kind (not a single shared bucket), matching how ARCHITECTURE already
  # gets its own bucket rather than folding into a language bucket.
  # Derived from the registry and ConceptBucket rather than restated. The
  # section-to-bucket rule already has exactly one home
  # (ConceptBucket::SPECIAL_BUCKETS); a second copy here could disagree with it,
  # and would make every new fourth kind edit this file as well as its own class.
  # The nil language is safe and load-bearing: every fourth kind's bucket is
  # language-independent, which is precisely why the fourth track can run on a
  # track of its own. A fourth kind that was not special would resolve to nil
  # here and fail the fetch below rather than silently sharing a language bucket.
  FOURTH_BUCKET_FOR = ExerciseSection.fourths
    .to_h { |kind| [ kind.key.to_sym, ConceptBucket.for(kind.key, nil) ] }
    .freeze

  # Always excluded from the non-fourth reinforcement pool, regardless of which
  # fourth kind rolls today — neither bucket is ever hostable in
  # code_review/pattern/third, so a fourth-bucket concept must never compete
  # for or claim one of those slots.
  FOURTH_BUCKETS = FOURTH_BUCKET_FOR.values.freeze

  # The fourth slot is exactly one section holding exactly one concept (see
  # AiService#exercise_schema_for). Everything competing for it — reinforcement
  # and retention alike — is sized against this, so the prompt can never ask a
  # one-concept section to carry two.
  FOURTH_SLOT_CAPACITY = 1

  # fourth_track's early return when no fourth section was chosen today.
  NO_FOURTH_TRACK = { fourth: nil, fourth_reinforcement: [], fourth_due_checks: [], fourth_established: [] }.freeze

  # Concept selection happens HERE rather than inside the prompt builder so the
  # caller can compare what was offered against what the model actually used —
  # the prompt builder is private and returns only a string, so it cannot report
  # that (see AiService#log_retention).
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
               scenario_flavor: WeightedRoll.pick(scenario_flavor_weights_for(user.skill_level)))
  end

  # Public so the dashboard's forecast of tomorrow composes the size the same
  # way. CompetencyGate.for replays every post-rubric day, so a plan calls it
  # once.
  def self.size_for(user, history)
    DaySize.for(setting: user.daily_section_count, completion: SectionCount.for(history), gate: CompetencyGate.for(user))
  end

  # The user's slice plus the bucket of the language being generated, which
  # differs from the setting when a regeneration keeps the stored exercise's
  # language after the user changed theirs.
  def self.due_buckets(user, language)
    ConceptBucket.slice_for(user.language) | [ language ]
  end
  private_class_method :due_buckets

  # Everything the day's chosen kinds decide about concepts. Computed again
  # when the coverage exception adds a kind, so the added section can take
  # the check it was added for.
  def self.concept_tracks(user, language, rotation, due:, hosts:)
    kinds  = ExerciseSection.for_plan(**rotation)
    tracks = main_track(user, language, kinds: kinds, hosts: hosts, due: due).merge(fourth_track(user, rotation.fetch(:fourth), due: due))

    tracks.merge(waiting_checks: waiting_checks(tracks, due, kinds: kinds, hosts: hosts))
  end
  private_class_method :concept_tracks

  # The added kind fills its slot and the tracks are decided again so the
  # check it was added for can land there. Reinforcement can still outrank
  # that check for the one retention slot, and then the addition is given up:
  # the day stays at two rather than spending the cap on a section that
  # carries something else.
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

  # Cheapest check first: the setting and count cost nothing, the cap one
  # small query, and only a day that passes both loads the gaps.
  def self.coverage_for(user, size, preferences, waiting, hosts)
    day = { count: size.count, fixed: size.setting, brake: size.brake? }
    return nil unless CoverageException.applies_to_day?(**day)

    recent = CoverageException::History.recent_coverage_dates(user)
    return nil if CoverageException.capped?(recent, Date.current)

    CoverageException.for(today: Date.current, **day, history: CoverageException::History.for(user, coverage_dates: recent),
                          checks: waiting, preferences: preferences, hosts: hosts)
  end
  private_class_method :coverage_for

  # Due checks across the user's whole slice that today does not offer, most
  # overdue first: no_slot when a section today could tag the concept but
  # the day's hosts went elsewhere, no_host when none could. A concept
  # reinforcement already carries is being worked, not waiting.
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

  # The non-fourth sections' concepts: reinforcement, the concept both fixed
  # sections share, retention checks and established concepts.
  #
  # Held to the buckets today can host, like retention and established
  # concepts: a mixed user's javascript entry on a ruby_rails day could
  # otherwise sit beside the ruby_rails retention check for the same name,
  # and the prompt, which names concepts without their bucket, would ask for
  # one name under two instructions.
  #
  # Only the non-fourth kinds present today can ever host a language or
  # architecture concept, so capacity follows the chosen set rather than a
  # literal 3 — a short day (pattern chosen but no third) has fewer hosts,
  # and this now says so structurally instead of by counting. Reinforcement
  # keeps every such slot by default; a slot is taken back for retention only
  # when reinforcement would otherwise claim all of them AND at least one
  # retention check, in a bucket today can actually host, has gone
  # meaningfully overdue (see ConceptMastery::RETENTION_OVERDUE_THRESHOLD_MULTIPLIER).
  # A merely-due check is not enough to spend a reinforcement slot on — only
  # a check nobody's gotten to in a while earns the trade.
  #
  # This capacity is approximate, deliberately. On a schema-review day
  # code_review hosts only data-modeling concepts, and design_comparison
  # hosts only its own allowlist every day, so an ordinary concept can have
  # a host or two fewer than this counts. Left approximate because the arithmetic
  # is advisory end to end — nothing verifies placement, and over-requesting
  # by one costs a concept the model could not have placed anyway. Making it
  # mode-aware would reopen this state machine, whose correctness rests on
  # structural separation rather than on arguments about interacting
  # conditions. AiService#log_retention already records offered-versus-
  # honored per bucket, so if this matters it will show up there first.
  #
  # Truncated to what today can actually host, and again when a retention
  # check takes a slot back: the prompt's mastery instruction demands every
  # concept listed here be reintroduced, so an entry past capacity is an
  # instruction no section is left to satisfy.
  #
  # The shared concept is decided last, from whatever host reinforcement and
  # retention left free, so pairing never displaces either.
  def self.main_track(user, language, kinds:, hosts:, due:)
    hostable      = hostable_buckets(language, kinds: kinds)
    reinforcement = user.concepts_needing_reinforcement(exclude_buckets: FOURTH_BUCKETS,
                                                        hostable: drill_host_test(kinds: kinds, hosts: hosts))
                        .select { |h| hostable.include?(h[:bucket]) }
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

  def self.scenario_flavor_weights_for(skill_level)
    SCENARIO_FLAVOR_WEIGHTS_BY_SKILL_LEVEL.fetch(skill_level, SCENARIO_FLAVOR_WEIGHTS)
  end

  # Whether today's code_review is grounded in Code Gym's own source, and in
  # which excerpt. Gated before it is rolled: only a day generating in the
  # language this codebase is written in can use it, and only a mode with a
  # pool — test_file has none. A second WeightedRoll inside the mode rather
  # than more entries in CODE_REVIEW_MODE_WEIGHTS, so the three-way mode
  # split stays exactly what it is and a grounded day is still that mode.
  # The excerpt is chosen here and read later, when the prompt is built.
  def self.code_review_source_for(user, language, mode)
    return nil unless language == RealSource::LANGUAGE && RealSource.pool(mode).any?
    return nil unless WeightedRoll.pick(RealSource::WEIGHTS) == :real

    RealSource.pick(mode, last_seen: RealSource.last_seen_for(user))
  end
  private_class_method :code_review_source_for

  # Drills lead, but a group drill with more members than hosts would
  # otherwise fill every slot every day until all of them cleared, and the
  # concept the ratings flagged would never come back. When evidence-driven
  # reinforcement is waiting, drills keep all but one host; a one-host day
  # still goes to the drill, since the cap's guarantee is about the fullest
  # day and a drill is the user's own request.
  def self.share_hosts(reinforcement, capacity)
    drilled, evidence = reinforcement.partition { |h| h[:drilled] }
    return reinforcement.first(capacity) if evidence.empty?

    (drilled.first([ capacity - 1, 1 ].max) + evidence).first(capacity)
  end
  private_class_method :share_hosts

  # Whether some non-fourth section today can tag a drilled concept, from the
  # same per-section vocabulary the prompt offers (AiService#can_host? reads
  # it for retention checks). Bucket-level hosting is not enough: an
  # application_code code_review cannot tag a data-modeling concept, and a
  # drill would otherwise claim that day's slot every time the mode rolled
  # that way. The bucket check keeps a mixed user's same-named concept in the
  # other language out.
  def self.drill_host_test(kinds:, hosts:)
    candidates = kinds.reject(&:fourth?)

    ->(concept, bucket) { hosts.hosts(candidates, concept, bucket).any? }
  end
  private_class_method :drill_host_test

  # The fourth slot's own independent track — a parallel state machine rather
  # than a generalization of the non-fourth pool above, because the two
  # vocabularies can never mix: keeping them structurally separate means a
  # cross-vocab item can never be placed somewhere it structurally cannot go.
  # Skipped entirely when no fourth section was chosen — there is no bucket to
  # run the track against.
  def self.fourth_track(user, fourth, due:)
    return NO_FOURTH_TRACK if fourth.nil?

    bucket = FOURTH_BUCKET_FOR.fetch(fourth)
    # Truncated to the slot's capacity before anything else reads it: the full
    # list runs 4-5 entries deep on a small vocabulary, and every entry past
    # the first is a concept the prompt would demand of a section that can only
    # carry one.
    reinforcement = user.concepts_needing_reinforcement(bucket: bucket).first(FOURTH_SLOT_CAPACITY)
    # An overdue retention check doesn't share the slot, it takes it — leaving
    # reinforcement in place alongside would put two mutually exclusive
    # concepts in the same prompt.
    reinforcement = [] if reinforcement.any? && overdue_retention_check_pending_for_bucket?(user, bucket, reinforcement: reinforcement)
    due_checks    = retention_checks_for_bucket(due, bucket, slots: FOURTH_SLOT_CAPACITY - reinforcement.size,
                                                reinforcement: reinforcement)

    { fourth: fourth, fourth_reinforcement: reinforcement, fourth_due_checks: due_checks,
      fourth_established: established_concepts_for_bucket(user, bucket, reinforcement: reinforcement,
                                                          due_checks: due_checks) }
  end
  private_class_method :fourth_track

  # Single-bucket analog of retention_checks_for. Simpler than the non-fourth
  # version: the fourth slot's bucket is always exactly one fixed value
  # (today's rolled kind), never a multi-bucket set the way hostable_buckets
  # can return for the third slot.
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

  # Single-bucket analog of overdue_retention_check_pending? — required, not
  # optional: every fourth-slot vocabulary is small, so it will
  # commonly have at least one concept needing reinforcement, which would
  # otherwise claim the slot every day and starve fourth_due_checks
  # permanently (the fourth slot has exactly one slot total, unlike the
  # non-fourth pool's several, so a single reinforcement concept blocks 100%
  # of its retention capacity rather than a fraction of it).
  def self.overdue_retention_check_pending_for_bucket?(user, bucket, reinforcement: [])
    claimed_here = claimed_concepts(reinforcement).filter_map { |concept, claimed_bucket| concept if claimed_bucket == bucket }

    user.concepts_overdue_for_retention_check(bucket: bucket).where.not(concept: claimed_here).exists?
  end
  private_class_method :overdue_retention_check_pending_for_bucket?

  # The concept buckets today's set can actually host. Architecture concepts have
  # no home outside the architecture third, and a language concept must match the
  # day's resolved generation language — otherwise a mixed-language user gets a
  # Rails concept on a JavaScript day. Both retention callers below share this so
  # the eligibility rule can never drift between deciding to reserve a slot and
  # deciding what fills it.
  def self.hostable_buckets(language, kinds:)
    buckets = [ language ]
    buckets << "architecture" if kinds.include?(ExerciseSection::Architecture)
    buckets
  end
  private_class_method :hostable_buckets

  # Due retention checks for the buckets this day can actually host, most overdue
  # RELATIVE TO EACH CONCEPT'S OWN INTERVAL first — the same ratio
  # overdue_retention_check_pending? uses to decide whether a slot gets reserved
  # at all. Sorting by raw due-date instead would let a long-interval concept
  # that's merely due outrank a short-interval one that's actually crossed the
  # overdue threshold, handing the reserved slot to a concept that didn't earn it.
  #
  # `due` is the user's whole slice, read once by .for; this keeps only the
  # checks some section today can tag, and truncates only after ranking, so
  # no date order or fetch cap can drop the concept this ranking exists to
  # surface. Tagging is DayHosts' test, the one waiting_checks reads, so a
  # check only a kind the day lacks could carry waits as no_host instead of
  # being selected here and then left out of the prompt.
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

  # A drill can put a mastered concept back in reinforcement, and its due
  # check would otherwise list the same concept twice in one prompt with two
  # different instructions. Reinforcement already asks for it fresh, so the
  # check stands down — the same "claimed" rule established_concepts_for uses
  # — and the overdue tests above ignore it too, so it cannot reserve or take
  # a slot for a concept the list already carries.
  def self.unclaimed_by(reinforcement, due_checks)
    claimed = claimed_concepts(reinforcement)
    due_checks.reject { |cm| claimed.include?([ cm.concept, cm.language ]) }
  end
  private_class_method :unclaimed_by

  # The (concept, bucket) pairs a prompt already asks for. Matched on the
  # pair, never the name: a mixed-language user's javascript over_mocking is
  # not their ruby_rails one (#190).
  def self.claimed_concepts(reinforcement, due_checks = [])
    reinforcement.map { |h| [ h[:concept], h[:bucket] ] } + due_checks.map { |cm| [ cm.concept, cm.language ] }
  end
  private_class_method :claimed_concepts

  # Days overdue divided by the concept's own retention_interval_days — the same
  # normalization concepts_overdue_for_retention_check applies in SQL, computed
  # in Ruby here since this list already spans multiple bucket queries. A nil or
  # zero interval (should not happen alongside a set next_retention_check_on, but
  # never trust that from a selection method) sorts last rather than raising.
  def self.overdue_ratio(cm)
    return -Float::INFINITY if cm.retention_interval_days.to_i <= 0
    (Date.current - cm.next_retention_check_on).to_f / cm.retention_interval_days
  end
  private_class_method :overdue_ratio

  # Standard tier and past the initial retention interval, meaning the concept
  # already survived a scheduled check rather than being mastered once and never
  # re-tested. Reinforcement and due checks carry their own, stronger prompt
  # annotation, so anything they claim is excluded here.
  def self.established_concepts_for(user, language, kinds:, reinforcement:, due_checks:)
    claimed = claimed_concepts(reinforcement, due_checks)

    established_in_buckets(user, hostable_buckets(language, kinds: kinds))
      .reject { |cm| claimed.include?([ cm.concept, cm.language ]) }
  end
  private_class_method :established_concepts_for

  # Each bucket contributes its OWN vocabulary condition, and the scopes are
  # OR-ed into one relation rather than enumerated per bucket, so an
  # architecture day still costs a single query. A single query over the union
  # of both vocabularies would instead let a language concept qualify by
  # matching the architecture list, or the reverse.
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

  # Whether reinforcement should give up a slot: only when some retention
  # check a section today can tag has crossed the "meaningfully overdue"
  # threshold (ConceptMastery::RETENTION_OVERDUE_THRESHOLD_MULTIPLIER). Read
  # from the same hostable list retention_checks_for fills the slot from, so
  # a slot is never reserved for a check nothing today could carry.
  def self.overdue_retention_check_pending?(due, kinds:, hosts:, reinforcement: [])
    unclaimed_by(reinforcement, hostable_checks(due, kinds: kinds, hosts: hosts))
      .any? { |cm| overdue_ratio(cm) >= ConceptMastery::RETENTION_OVERDUE_THRESHOLD_MULTIPLIER }
  end
  private_class_method :overdue_retention_check_pending?
end
