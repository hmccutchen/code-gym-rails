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
                        :code_review_mode)

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

  # Bounds the per-bucket due-concept fetch without truncating it. Not
  # truncating is the point, not a nicety: the query orders by
  # next_retention_check_on — absolute days overdue — while
  # retention_checks_for re-ranks by overdue RATIO against each concept's own
  # interval. Those orderings disagree, so a cap that actually cut rows would
  # discard by date the row the re-rank was about to pick by ratio (issue #93,
  # where a hardcoded 20 outlived two vocabulary additions).
  #
  # A bucket holds at most one row per concept — unique index on
  # (user_id, concept, language), and ConceptMastery.record_review! never
  # records "other". concepts_due_for_retention_check additionally filters on
  # vocabulary membership, so a concept later renamed or removed drops out of
  # the fetch rather than lingering: the ceiling is the bucket's CURRENT
  # vocabulary, not every name ever valid in it. Sizing against the largest
  # vocabulary therefore cannot truncate.
  RETENTION_BUCKET_FETCH_CAP = AiService::LANGUAGE_CONFIG.values.map { |config| config.fetch(:concepts).size }.max

  # fourth_track's early return when no fourth section was chosen today.
  NO_FOURTH_TRACK = { fourth: nil, fourth_reinforcement: [], fourth_due_checks: [], fourth_established: [] }.freeze

  # Concept selection happens HERE rather than inside the prompt builder so the
  # caller can compare what was offered against what the model actually used —
  # the prompt builder is private and returns only a string, so it cannot report
  # that (see AiService#log_retention).
  def self.for(user, language:)
    history       = user.recent_exercise_history(limit: SectionRotation::LOOKBACK)
    rotation      = SectionRotation.for(history, count: SectionCount.for(history, adaptive: user.adaptive_set_size?))
    kinds         = ExerciseSection.for_plan(**rotation)
    reinforcement = user.concepts_needing_reinforcement(exclude_buckets: FOURTH_BUCKETS)
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
    # code_review hosts only data-modeling concepts, so an ordinary concept has
    # one host fewer than this counts. Left approximate because the arithmetic
    # is advisory end to end — nothing verifies placement, and over-requesting
    # by one costs a concept the model could not have placed anyway. Making it
    # mode-aware would reopen this state machine, whose correctness rests on
    # structural separation rather than on arguments about interacting
    # conditions. AiService#log_retention already records offered-versus-
    # honored per bucket, so if this matters it will show up there first.
    capacity      = kinds.count { |kind| !kind.fourth? }
    reinforcement = reinforcement.first(capacity)
    slots         = capacity - reinforcement.size
    slots         = 1 if slots.zero? && overdue_retention_check_pending?(user, language, kinds: kinds)
    # Truncated to what today can actually host, and again when a retention
    # check takes a slot back: the prompt's mastery instruction demands every
    # concept listed here be reintroduced, so an entry past capacity is an
    # instruction no section is left to satisfy.
    reinforcement = reinforcement.first(capacity - slots)
    due_checks    = retention_checks_for(user, language, kinds: kinds, slots: slots)
    established   = established_concepts_for(user, language, kinds: kinds,
                                             reinforcement: reinforcement, due_checks: due_checks)

    Result.new(pattern: rotation.fetch(:pattern), third: rotation.fetch(:third),
               reinforcement: reinforcement, due_checks: due_checks, established: established,
               code_review_mode: WeightedRoll.pick(CODE_REVIEW_MODE_WEIGHTS),
               **fourth_track(user, rotation.fetch(:fourth)))
  end

  # The fourth slot's own independent track — a parallel state machine rather
  # than a generalization of the non-fourth pool above, because the two
  # vocabularies can never mix: keeping them structurally separate means a
  # cross-vocab item can never be placed somewhere it structurally cannot go.
  # Skipped entirely when no fourth section was chosen — there is no bucket to
  # run the track against.
  def self.fourth_track(user, fourth)
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
    reinforcement = [] if reinforcement.any? && overdue_retention_check_pending_for_bucket?(user, bucket)
    due_checks    = retention_checks_for_bucket(user, bucket, slots: FOURTH_SLOT_CAPACITY - reinforcement.size)

    { fourth: fourth, fourth_reinforcement: reinforcement, fourth_due_checks: due_checks,
      fourth_established: established_concepts_for_bucket(user, bucket, reinforcement: reinforcement,
                                                          due_checks: due_checks) }
  end
  private_class_method :fourth_track

  # Single-bucket analog of retention_checks_for. Simpler than the non-fourth
  # version: the fourth slot's bucket is always exactly one fixed value
  # (today's rolled kind), never a multi-bucket set the way hostable_buckets
  # can return for the third slot.
  def self.retention_checks_for_bucket(user, bucket, slots:)
    return [] if slots.zero?

    user.concepts_due_for_retention_check(bucket: bucket, limit: RETENTION_BUCKET_FETCH_CAP)
        .to_a
        .sort_by { |cm| -(overdue_ratio(cm)) }
        .first(slots)
  end
  private_class_method :retention_checks_for_bucket

  # Single-bucket analog of established_concepts_for.
  def self.established_concepts_for_bucket(user, bucket, reinforcement:, due_checks:)
    claimed = reinforcement.map { |h| h[:concept] } + due_checks.map(&:concept)

    established_in_buckets(user, [ bucket ]).reject { |cm| claimed.include?(cm.concept) }
  end
  private_class_method :established_concepts_for_bucket

  # Single-bucket analog of overdue_retention_check_pending? — required, not
  # optional: every fourth-slot vocabulary is small, so it will
  # commonly have at least one concept needing reinforcement, which would
  # otherwise claim the slot every day and starve fourth_due_checks
  # permanently (the fourth slot has exactly one slot total, unlike the
  # non-fourth pool's several, so a single reinforcement concept blocks 100%
  # of its retention capacity rather than a fraction of it).
  def self.overdue_retention_check_pending_for_bucket?(user, bucket)
    user.concepts_overdue_for_retention_check(bucket: bucket).exists?
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
  # The per-bucket query is fetched WITHOUT truncating to `slots` — passing
  # `limit: slots` there would let SQL's raw-date ORDER BY throw away the very
  # concept this ranking exists to surface before overdue_ratio ever saw it.
  def self.retention_checks_for(user, language, kinds:, slots:)
    return [] if slots.zero?

    hostable_buckets(language, kinds: kinds)
      .flat_map { |bucket| user.concepts_due_for_retention_check(bucket: bucket, limit: RETENTION_BUCKET_FETCH_CAP).to_a }
      .sort_by { |cm| -(overdue_ratio(cm)) }
      .first(slots)
  end
  private_class_method :retention_checks_for

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
    claimed = reinforcement.map { |h| h[:concept] } + due_checks.map(&:concept)

    established_in_buckets(user, hostable_buckets(language, kinds: kinds))
      .reject { |cm| claimed.include?(cm.concept) }
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
  # check, in a bucket today's kinds can actually host, has crossed the
  # "meaningfully overdue" threshold (ConceptMastery::RETENTION_OVERDUE_THRESHOLD_MULTIPLIER).
  # Sharing hostable_buckets with retention_checks_for is what stops an
  # architecture-only overdue concept from forcing a slot on a challenge day it
  # could never occupy.
  def self.overdue_retention_check_pending?(user, language, kinds:)
    hostable_buckets(language, kinds: kinds)
      .any? { |bucket| user.concepts_overdue_for_retention_check(bucket: bucket).exists? }
  end
  private_class_method :overdue_retention_check_pending?
end
