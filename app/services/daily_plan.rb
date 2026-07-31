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
  Result = Data.define(:third, :reinforcement, :due_checks, :established)

  # Which third section this set gets. Named, tunable weights rather than a
  # bare literal: architecture-reasoning most of the time, the other three kinds
  # evenly splitting the rest.
  # Extracted so tests can stub it — never assert on real randomness. The
  # chosen kind is not tracked separately; the persisted third key
  # (ExerciseSection.thirds) is the record.
  THIRD_SECTION_WEIGHTS = { architecture: 0.40, security_review: 0.20, challenge: 0.20, parsons_problem: 0.20 }.freeze

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
    third         = roll_third_section
    reinforcement = user.concepts_needing_reinforcement
    # An exercise has only 3 sections, so only the first 3 reinforcement concepts
    # can ever occupy one — sizing against the full (often 4-8 entry) list left
    # slots permanently at 0 for any active user. Reinforcement keeps all 3 slots
    # by default; a slot is taken back for retention only when reinforcement
    # would otherwise claim all three AND at least one retention check, in a
    # bucket today can actually host, has gone meaningfully overdue (see
    # ConceptMastery::RETENTION_OVERDUE_THRESHOLD_MULTIPLIER). A merely-due check
    # is not enough to spend a reinforcement slot on — only a check nobody's
    # gotten to in a while earns the trade.
    slots         = 3 - reinforcement.first(3).size
    slots         = 1 if slots.zero? && overdue_retention_check_pending?(user, language, third: third)
    due_checks    = retention_checks_for(user, language, third: third, slots: slots)
    established   = established_concepts_for(user, language, third: third,
                                             reinforcement: reinforcement, due_checks: due_checks)

    Result.new(third: third, reinforcement: reinforcement, due_checks: due_checks, established: established)
  end

  # Cumulative weights are rounded before comparison: summing float weights
  # (0.40 + 0.20 == 0.6000000000000001) otherwise shifts each boundary by an
  # ulp and hands the wrong kind back at the exact boundary value.
  def self.roll_third_section
    r = rand
    cumulative = 0.0

    THIRD_SECTION_WEIGHTS.each do |kind, weight|
      cumulative += weight
      return kind if r < cumulative.round(10)
    end

    THIRD_SECTION_WEIGHTS.keys.last
  end
  private_class_method :roll_third_section

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
