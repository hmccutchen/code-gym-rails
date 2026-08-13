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
  Result = Data.define(:third, :reinforcement, :due_checks, :established,
                        :fourth, :fourth_reinforcement, :fourth_due_checks, :fourth_established,
                        :code_review_mode)

  # Which third section this set gets. Equal weights: the four kinds exercise
  # different reasoning and none is the baseline the others vary from, so
  # variety beats depth-in-one-area here. This deliberately reverses an
  # earlier bias toward architecture (0.75, then 0.50, then 0.40).
  # The chosen kind is not tracked separately; the persisted third key
  # (ExerciseSection.thirds) is the record.
  THIRD_SECTION_WEIGHTS = { architecture: 0.25, security_review: 0.25, challenge: 0.25, parsons_problem: 0.25 }.freeze

  # The fourth slot's two kinds, 50/50 — as with the third slot, there's no
  # reason to favor one of these two skills over the other.
  FOURTH_SECTION_WEIGHTS = { plan_review: 0.5, ambiguity_hunt: 0.5 }.freeze

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
  FOURTH_BUCKET_FOR = { plan_review: ConceptBucket::PLAN_REVIEW, ambiguity_hunt: ConceptBucket::AMBIGUITY_HUNT }.freeze

  # Always excluded from the 3-slot reinforcement pool, regardless of which
  # fourth kind rolls today — neither bucket is ever hostable in
  # code_review/pattern/third, so a fourth-bucket concept must never compete
  # for or claim one of those three slots.
  FOURTH_BUCKETS = FOURTH_BUCKET_FOR.values.freeze

  # The fourth slot is exactly one section holding exactly one concept (see
  # AiService#exercise_schema_for). Everything competing for it — reinforcement
  # and retention alike — is sized against this, so the prompt can never ask a
  # one-concept section to carry two.
  FOURTH_SLOT_CAPACITY = 1

  # A vocabulary is at most 16 concepts (see AiService::RAILS_CONCEPTS /
  # JS_CONCEPTS / ARCHITECTURE_CONCEPTS), so "every due concept in a bucket" is
  # never a large fetch — this exists only so the per-bucket query below doesn't
  # truncate to `slots` before the overdue-ratio re-rank gets a chance to run
  # across all of them (see retention_checks_for's comment).
  RETENTION_BUCKET_FETCH_CAP = 20

  # Concept selection happens HERE rather than inside the prompt builder so the
  # caller can compare what was offered against what the model actually used —
  # the prompt builder is private and returns only a string, so it cannot report
  # that (see AiService#log_retention).
  def self.for(user, language:)
    third         = roll_weighted(THIRD_SECTION_WEIGHTS)
    reinforcement = user.concepts_needing_reinforcement(exclude_buckets: FOURTH_BUCKETS)
    # An exercise has only 3 sections, so only the first 3 reinforcement concepts
    # can ever occupy one — sizing against the full (often 4-8 entry) list left
    # slots permanently at 0 for any active user. Reinforcement keeps all 3 slots
    # by default; a slot is taken back for retention only when reinforcement
    # would otherwise claim all three AND at least one retention check, in a
    # bucket today can actually host, has gone meaningfully overdue (see
    # ConceptMastery::RETENTION_OVERDUE_THRESHOLD_MULTIPLIER). A merely-due check
    # is not enough to spend a reinforcement slot on — only a check nobody's
    # gotten to in a while earns the trade.
    #
    # This 3 is approximate, deliberately. On a schema-review day code_review
    # hosts only data-modeling concepts, so an ordinary concept has two hosts
    # rather than three. Left approximate because the arithmetic is advisory
    # end to end — nothing verifies placement, and over-requesting by one costs
    # a concept the model could not have placed anyway. Making it mode-aware
    # would reopen this state machine, whose correctness rests on structural
    # separation rather than on arguments about interacting conditions.
    # AiService#log_retention already records offered-versus-honored per
    # bucket, so if this matters it will show up there first.
    slots         = 3 - reinforcement.first(3).size
    slots         = 1 if slots.zero? && overdue_retention_check_pending?(user, language, third: third)
    due_checks    = retention_checks_for(user, language, third: third, slots: slots)
    established   = established_concepts_for(user, language, third: third,
                                             reinforcement: reinforcement, due_checks: due_checks)

    # The fourth slot's own independent track — a parallel state machine
    # rather than a generalization of the 3-slot one above, because the two
    # vocabularies can never mix: keeping them structurally separate means a
    # cross-vocab item can never be placed somewhere it structurally cannot go.
    fourth               = roll_weighted(FOURTH_SECTION_WEIGHTS)
    fourth_bucket        = FOURTH_BUCKET_FOR.fetch(fourth)
    # Truncated to the slot's capacity before anything else reads it: the full
    # list runs 4-5 entries deep on a small vocabulary, and every entry past
    # the first is a concept the prompt would demand of a section that can only
    # carry one.
    fourth_reinforcement = user.concepts_needing_reinforcement(bucket: fourth_bucket).first(FOURTH_SLOT_CAPACITY)
    # An overdue retention check doesn't share the slot, it takes it — leaving
    # reinforcement in place alongside would put two mutually exclusive
    # concepts in the same prompt.
    fourth_reinforcement = [] if fourth_reinforcement.any? &&
                                 overdue_retention_check_pending_for_bucket?(user, fourth_bucket)
    fourth_slots         = FOURTH_SLOT_CAPACITY - fourth_reinforcement.size
    fourth_due_checks    = retention_checks_for_bucket(user, fourth_bucket, slots: fourth_slots)
    fourth_established   = established_concepts_for_bucket(user, fourth_bucket,
                                                            reinforcement: fourth_reinforcement, due_checks: fourth_due_checks)

    code_review_mode = roll_weighted(CODE_REVIEW_MODE_WEIGHTS)

    Result.new(third: third, reinforcement: reinforcement, due_checks: due_checks, established: established,
               fourth: fourth, fourth_reinforcement: fourth_reinforcement,
               fourth_due_checks: fourth_due_checks, fourth_established: fourth_established,
               code_review_mode: code_review_mode)
  end

  # Cumulative weights are rounded before comparison: summing float weights can
  # land an ulp off the intended boundary (0.40 + 0.20 == 0.6000000000000001,
  # from the earlier third-slot weights), handing the wrong kind back at the
  # exact boundary value. No table here drifts today; the guard stays because
  # the next set of weights added may.
  # Extracted so tests can stub it — never assert on real randomness.
  def self.roll_weighted(weights)
    r = rand
    cumulative = 0.0

    weights.each do |kind, weight|
      cumulative += weight
      return kind if r < cumulative.round(10)
    end

    weights.keys.last
  end
  private_class_method :roll_weighted

  # Single-bucket analog of retention_checks_for. Simpler than the 3-slot
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

    user.concept_masteries
      .where(language: bucket, tier: :standard)
      .where("retention_interval_days > ?", ConceptMastery::RETENTION_INITIAL_INTERVAL_DAYS)
      .reject { |cm| claimed.include?(cm.concept) }
  end
  private_class_method :established_concepts_for_bucket

  # Single-bucket analog of overdue_retention_check_pending? — required, not
  # optional: each fourth-slot vocabulary is only 4-5 concepts, so it will
  # commonly have at least one concept needing reinforcement, which would
  # otherwise claim the slot every day and starve fourth_due_checks
  # permanently (the fourth slot has exactly one slot total, unlike the
  # 3-slot pool's three, so a single reinforcement concept blocks 100% of its
  # retention capacity rather than a third of it).
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
  def self.hostable_buckets(language, third:)
    buckets = [ language ]
    buckets << "architecture" if third == :architecture
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
  def self.retention_checks_for(user, language, third:, slots:)
    return [] if slots.zero?

    hostable_buckets(language, third: third)
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
  def self.established_concepts_for(user, language, third:, reinforcement:, due_checks:)
    claimed = reinforcement.map { |h| h[:concept] } + due_checks.map(&:concept)

    user.concept_masteries
      .where(language: hostable_buckets(language, third: third), tier: :standard)
      .where("retention_interval_days > ?", ConceptMastery::RETENTION_INITIAL_INTERVAL_DAYS)
      .reject { |cm| claimed.include?(cm.concept) }
  end
  private_class_method :established_concepts_for

  # Whether reinforcement should give up its 3rd slot: only when some retention
  # check, in a bucket today's third can actually host, has crossed the
  # "meaningfully overdue" threshold (ConceptMastery::RETENTION_OVERDUE_THRESHOLD_MULTIPLIER).
  # Sharing hostable_buckets with retention_checks_for is what stops an
  # architecture-only overdue concept from forcing a slot on a challenge day it
  # could never occupy.
  def self.overdue_retention_check_pending?(user, language, third:)
    hostable_buckets(language, third: third)
      .any? { |bucket| user.concepts_overdue_for_retention_check(bucket: bucket).exists? }
  end
  private_class_method :overdue_retention_check_pending?
end
