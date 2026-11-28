require "rails_helper"

module DailyPlanSelectionStubs
  def pin_kind(key)
    kind = ExerciseSection.for(key)
    allow(PracticeSchedule).to receive(:single_turn).and_wrap_original do |original, **options|
      preferences = options.fetch(:preferences).dup
      allow(preferences).to receive(:offered).with(daily: options.fetch(:daily)).and_return([ kind ])
      original.call(**options.merge(preferences: preferences))
    end
  end
end

RSpec.describe DailyPlan do
  include DailyPlanSelectionStubs
  # rails_helper includes AuthHelpers by spec type, and spec/services has no inferred type.
  include AuthHelpers
  before { pin_kind("code_review") }

  it "ignores every historical fixed count without replaying capacity" do
    user = create_user_with_key
    expect(CompetencyGate).not_to receive(:for)
    (1..4).each do |count|
      user.daily_section_count = count
      decision = described_class.size_for(user)
      expect(decision).to have_attributes(count: 1, reason: :single)
      expect(decision.diagnostics[:gate]).to be_nil
      expect(decision.brake?).to be(false)
    end
  end

  describe "FOURTH_BUCKET_FOR" do
    it "gives every fourth-slot kind its own bucket" do
      expect(DailyPlan::FOURTH_BUCKET_FOR.keys.map(&:to_s))
        .to match_array(ExerciseSection.fourths.map(&:key))
      expect(DailyPlan::FOURTH_BUCKET_FOR[:pseudocode_to_code]).to eq(ConceptBucket::PSEUDOCODE_TO_CODE)
      expect(DailyPlan::FOURTH_BUCKET_FOR.values).to all(be_present)
      expect(DailyPlan::FOURTH_BUCKET_FOR.values.uniq.size).to eq(DailyPlan::FOURTH_BUCKET_FOR.size)
    end
  end
  let(:user) { User.create!(email: "prompt@example.com") }

  def due_slice
    user.concepts_due_for_retention_check_in(ConceptBucket.slice_for("mixed"))
  end

  def day_hosts
    DayHosts.new("ruby_rails", mode: :application_code)
  end

  describe "retention check selection" do
    [ false, true ].each do |captured|
      it "gives the single inactive host to an overdue check with #{captured ? 'an inactive capture' : 'no schedule context'}" do
        pin_code_review_mode(:application_code)
        reinforcement = %w[n_plus_one memoization].map do |concept|
          { concept: concept, bucket: "ruby_rails", tier: "standard" }
        end
        allow(user).to receive(:concepts_needing_reinforcement).and_return(reinforcement)
        check = user.concept_masteries.create!(concept: "transaction_safety", language: "ruby_rails", tier: :standard,
          mastered_at: 6.months.ago, retention_interval_days: 7, next_retention_check_on: Date.yesterday)
        context = { active: false, date: Date.current, note: {}, replacing_id: nil } if captured

        ordinary = described_class.for(user, language: "ruby_rails", schedule_context: context)
        expect(ordinary.kinds).to eq([ ExerciseSection::CodeReview ])
        expect(ordinary.reinforcement).to eq([ reinforcement.first ])
        expect(ordinary.due_checks).to be_empty

        overdue_on = 6.months.ago.to_date
        check.update!(next_retention_check_on: overdue_on)
        overdue = described_class.for(user, language: "ruby_rails", schedule_context: context)

        expect(overdue.kinds).to eq([ ExerciseSection::CodeReview ])
        expect(overdue.reinforcement).to be_empty
        expect(overdue.due_checks).to eq([ check ])
        expect(overdue.practice_schedule).to be_nil
        expect(check.reload.next_retention_check_on).to eq(overdue_on)
      end
    end

    it "releases the fourth slot after a skipped due check and leaves a not-yet-due repeat unchanged" do
      user.update!(daily_section_count: ExerciseSection::MAX_SECTIONS)
      pin_kind("plan_review")
      first, second = ConceptVocabulary::PLAN_REVIEW_CONCEPTS.first(2)
      held = user.concept_masteries.create!(concept: first, language: "plan_review",
        mastered_at: 1.month.ago, retention_interval_days: 7, next_retention_check_on: Date.current - 20)
      other = user.concept_masteries.create!(concept: second, language: "plan_review",
        mastered_at: 1.month.ago, retention_interval_days: 7, next_retention_check_on: Date.current - 1)
      expect(DailyPlan.for(user, language: "ruby_rails").fourth_due_checks.map(&:concept)).to eq([ first ])

      2.times do |offset|
        travel_to((Date.current + offset).noon) do
          exercise = user.daily_exercises.create!(date: Date.current, language: "ruby_rails",
            generated_at: Time.current, problem_set: { "plan_review" => { "concept" => first } })
          response = user.daily_responses.create!(daily_exercise: exercise, date: Date.current,
            submitted_at: Time.current, answers: {}, concept_tags: { "plan_review" => first },
            ai_review: { "plan_review" => { "rating" => "beginner" } })
          apply_mastery_review!(response, sections: %w[plan_review], apply_session_countdown: false)
        end
      end

      travel_to(2.days.from_now) do
        plan = DailyPlan.for(user, language: "ruby_rails")
        expect(plan.fourth_due_checks.map(&:concept)).to eq([ other.concept ])
        expect(held.reload.retention_interval_days).to eq(7)
      end
    end

    def mastery(concept:, bucket:, due_on:)
      user.concept_masteries.create!(concept: concept, language: bucket, tier: :standard,
                                     mastered_at: 1.month.ago, retention_interval_days: 7,
                                     next_retention_check_on: due_on)
    end

    it "fills only the slots reinforcement did not claim" do
      mastery(concept: "memoization", bucket: "ruby_rails", due_on: Date.current - 2)
      allow(user).to receive(:concepts_needing_reinforcement)
        .and_return([ { concept: "a", bucket: "ruby_rails", tier: "standard" }, { concept: "b", bucket: "ruby_rails", tier: "standard" } ])

      checks = DailyPlan.send(:retention_checks_for, due_slice, kinds: [ ExerciseSection::Challenge ], hosts: day_hosts, slots: 1)
      expect(checks.map(&:concept)).to eq(%w[memoization])
    end

    it "prioritizes a threshold-crossed short-interval concept over a merely-due long-interval one" do
      user.concept_masteries.create!(concept: "n_plus_one", language: "ruby_rails", tier: :standard,
                                     mastered_at: 2.months.ago, retention_interval_days: 28,
                                     next_retention_check_on: Date.current - 20)
      user.concept_masteries.create!(concept: "memoization", language: "ruby_rails", tier: :standard,
                                     mastered_at: 1.month.ago, retention_interval_days: 7,
                                     next_retention_check_on: Date.current - 10)

      checks = DailyPlan.send(:retention_checks_for, due_slice, kinds: [ ExerciseSection::Challenge ], hosts: day_hosts, slots: 1)
      expect(checks.map(&:concept)).to eq(%w[memoization])
    end

    it "sees a high-ratio concept whose due date sorts it past a fixed 20-row fetch (issue #93)" do
      (ConceptVocabulary::RAILS_CONCEPTS - %w[memoization]).first(20).each do |concept|
        user.concept_masteries.create!(concept: concept, language: "ruby_rails", tier: :standard,
                                       mastered_at: 6.months.ago, retention_interval_days: 90,
                                       next_retention_check_on: Date.current - 40)
      end
      user.concept_masteries.create!(concept: "memoization", language: "ruby_rails", tier: :standard,
                                     mastered_at: 1.month.ago, retention_interval_days: 7,
                                     next_retention_check_on: Date.current - 5)

      checks = DailyPlan.send(:retention_checks_for, due_slice, kinds: [ ExerciseSection::Challenge ], hosts: day_hosts, slots: 1)
      expect(checks.map(&:concept)).to eq(%w[memoization])
    end

    it "offers nothing when reinforcement already claims three slots" do
      mastery(concept: "memoization", bucket: "ruby_rails", due_on: Date.current - 2)
      expect(DailyPlan.send(:retention_checks_for, due_slice, kinds: [ ExerciseSection::Challenge ], hosts: day_hosts, slots: 0)).to eq([])
    end

    it "offers architecture-bucket concepts only on architecture days" do
      mastery(concept: "service_boundaries", bucket: "architecture", due_on: Date.current - 2)

      on_challenge = DailyPlan.send(:retention_checks_for, due_slice, kinds: [ ExerciseSection::Challenge ], hosts: day_hosts, slots: 3)
      on_arch      = DailyPlan.send(:retention_checks_for, due_slice, kinds: [ ExerciseSection::Architecture ], hosts: day_hosts, slots: 3)

      expect(on_challenge.map(&:concept)).to eq([])
      expect(on_arch.map(&:concept)).to eq(%w[service_boundaries])
    end

    it "never offers a concept from the other language's bucket" do
      mastery(concept: "closures", bucket: "javascript", due_on: Date.current - 2)
      checks = DailyPlan.send(:retention_checks_for, due_slice, kinds: [ ExerciseSection::Challenge ], hosts: day_hosts, slots: 3)
      expect(checks.map(&:concept)).to eq([])
    end
  end

  describe "established concept selection" do
    def established_mastery(concept:, bucket: "ruby_rails", interval: 14)
      user.concept_masteries.create!(concept: concept, language: bucket, tier: :standard,
                                     mastered_at: 2.months.ago, retention_interval_days: interval,
                                     next_retention_check_on: Date.current + 5)
    end

    it "excludes a concept no longer in the bucket's vocabulary, which the generator cannot use (issue #97)" do
      established_mastery(concept: "memoization")
      established_mastery(concept: "retired_concept")

      result = DailyPlan.send(:established_concepts_for, user, "ruby_rails", kinds: [ ExerciseSection::Challenge ],
                              reinforcement: [], due_checks: [])
      expect(result.map(&:concept)).to eq(%w[memoization])
    end

    it "matches each bucket against its own vocabulary, not the union" do
      established_mastery(concept: "service_boundaries", bucket: "ruby_rails")
      established_mastery(concept: "memoization",        bucket: "architecture")

      result = DailyPlan.send(:established_concepts_for, user, "ruby_rails", kinds: [ ExerciseSection::Architecture ],
                              reinforcement: [], due_checks: [])
      expect(result.map(&:concept)).to eq([])
    end

    it "excludes a concept no longer in the fourth slot's vocabulary" do
      established_mastery(concept: "scope_creep",      bucket: "plan_review")
      established_mastery(concept: "retired_concept",  bucket: "plan_review")

      result = DailyPlan.send(:established_concepts_for_bucket, user, "plan_review",
                              reinforcement: [], due_checks: [])
      expect(result.map(&:concept)).to eq(%w[scope_creep])
    end

    it "spans both buckets in a single query" do
      established_mastery(concept: "memoization",        bucket: "ruby_rails")
      established_mastery(concept: "service_boundaries", bucket: "architecture")

      queries = 0
      sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        queries += 1 unless payload[:name].to_s =~ /SCHEMA|TRANSACTION/
      end

      result = DailyPlan.send(:established_concepts_for, user, "ruby_rails",
                              kinds: [ ExerciseSection::CodeReview, ExerciseSection::Architecture ], reinforcement: [], due_checks: [])
      result.map(&:concept)

      expect(queries).to eq(1)
      expect(result.map(&:concept)).to match_array(%w[memoization service_boundaries])
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end

    it "includes standard-tier concepts past their initial retention interval" do
      established_mastery(concept: "memoization", interval: 14)

      result = DailyPlan.send(:established_concepts_for, user, "ruby_rails", kinds: [ ExerciseSection::Challenge ],
                              reinforcement: [], due_checks: [])
      expect(result.map(&:concept)).to eq(%w[memoization])
    end

    it "excludes concepts still on their initial interval (never survived a retention check)" do
      established_mastery(concept: "memoization", interval: 7)

      result = DailyPlan.send(:established_concepts_for, user, "ruby_rails", kinds: [ ExerciseSection::Challenge ],
                              reinforcement: [], due_checks: [])
      expect(result).to eq([])
    end

    it "excludes concepts already claimed by reinforcement" do
      established_mastery(concept: "memoization", interval: 14)

      result = DailyPlan.send(:established_concepts_for, user, "ruby_rails", kinds: [ ExerciseSection::Challenge ],
                              reinforcement: [ { concept: "memoization", bucket: "ruby_rails", tier: "standard" } ], due_checks: [])
      expect(result).to eq([])
    end

    it "excludes concepts already claimed by today's due retention checks" do
      cm = established_mastery(concept: "memoization", interval: 14)

      result = DailyPlan.send(:established_concepts_for, user, "ruby_rails", kinds: [ ExerciseSection::Challenge ],
                              reinforcement: [], due_checks: [ cm ])
      expect(result).to eq([])
    end

    it "excludes reduced and paused tier concepts" do
      user.concept_masteries.create!(concept: "n_plus_one", language: "ruby_rails", tier: :reduced,
                                     retention_interval_days: nil)
      user.concept_masteries.create!(concept: "scope_chaining", language: "ruby_rails", tier: :paused,
                                     retention_interval_days: nil, cooldown_remaining: 2)

      result = DailyPlan.send(:established_concepts_for, user, "ruby_rails", kinds: [ ExerciseSection::Challenge ],
                              reinforcement: [], due_checks: [])
      expect(result).to eq([])
    end

    it "only includes architecture-bucket concepts on architecture days, like retention checks do" do
      established_mastery(concept: "service_boundaries", bucket: "architecture", interval: 14)

      on_challenge = DailyPlan.send(:established_concepts_for, user, "ruby_rails", kinds: [ ExerciseSection::Challenge ],
                                    reinforcement: [], due_checks: [])
      on_arch      = DailyPlan.send(:established_concepts_for, user, "ruby_rails", kinds: [ ExerciseSection::Architecture ],
                                    reinforcement: [], due_checks: [])

      expect(on_challenge).to eq([])
      expect(on_arch.map(&:concept)).to eq(%w[service_boundaries])
    end
  end

  describe "#for" do
    it "includes established in the returned Result" do
      user.concept_masteries.create!(concept: "memoization", language: "ruby_rails", tier: :standard,
                                     mastered_at: 2.months.ago, retention_interval_days: 14,
                                     next_retention_check_on: Date.current + 5)

      result = DailyPlan.for(user, language: "ruby_rails")
      expect(result.established.map(&:concept)).to eq(%w[memoization])
    end
  end

  describe "fourth-slot retention check selection" do
    it "offers a due plan_review-bucket concept only when the bucket matches" do
      user.concept_masteries.create!(concept: "scope_creep", language: "plan_review", tier: :standard,
                                     mastered_at: 1.month.ago, retention_interval_days: 7,
                                     next_retention_check_on: Date.current - 2)

      matching    = DailyPlan.send(:retention_checks_for_bucket, due_slice, "plan_review", slots: 1)
      non_matching = DailyPlan.send(:retention_checks_for_bucket, due_slice, "ambiguity_hunt", slots: 1)

      expect(matching.map(&:concept)).to eq(%w[scope_creep])
      expect(non_matching.map(&:concept)).to eq([])
    end

    it "offers nothing when slots is zero" do
      user.concept_masteries.create!(concept: "scope_creep", language: "plan_review", tier: :standard,
                                     mastered_at: 1.month.ago, retention_interval_days: 7,
                                     next_retention_check_on: Date.current - 2)
      expect(DailyPlan.send(:retention_checks_for_bucket, due_slice, "plan_review", slots: 0)).to eq([])
    end
  end

  describe "fourth-slot established concept selection" do
    it "includes standard-tier concepts past their initial retention interval, in the given bucket" do
      user.concept_masteries.create!(concept: "scope_creep", language: "plan_review", tier: :standard,
                                     mastered_at: 2.months.ago, retention_interval_days: 14,
                                     next_retention_check_on: Date.current + 5)

      result = DailyPlan.send(:established_concepts_for_bucket, user, "plan_review",
                              reinforcement: [], due_checks: [])
      expect(result.map(&:concept)).to eq(%w[scope_creep])
    end

    it "excludes concepts already claimed by fourth-slot reinforcement or due checks" do
      cm = user.concept_masteries.create!(concept: "scope_creep", language: "plan_review", tier: :standard,
                                          mastered_at: 2.months.ago, retention_interval_days: 14,
                                          next_retention_check_on: Date.current + 5)

      by_reinforcement = DailyPlan.send(:established_concepts_for_bucket, user, "plan_review",
                                        reinforcement: [ { concept: "scope_creep", bucket: "plan_review", tier: "standard" } ], due_checks: [])
      by_due_check      = DailyPlan.send(:established_concepts_for_bucket, user, "plan_review",
                                        reinforcement: [], due_checks: [ cm ])

      expect(by_reinforcement).to eq([])
      expect(by_due_check).to eq([])
    end
  end

  describe "#overdue_retention_check_pending_for_bucket?" do
    it "is true only once a due check has crossed its own overdue threshold" do
      user.concept_masteries.create!(concept: "scope_creep", language: "plan_review", tier: :standard,
                                     mastered_at: 1.month.ago, retention_interval_days: 7,
                                     next_retention_check_on: Date.current - 1)
      expect(DailyPlan.send(:overdue_retention_check_pending_for_bucket?, user, "plan_review", hostable: ->(*) { true })).to be(false)

      user.concept_masteries.find_by(concept: "scope_creep").update!(next_retention_check_on: Date.current - 10)
      expect(DailyPlan.send(:overdue_retention_check_pending_for_bucket?, user, "plan_review", hostable: ->(*) { true })).to be(true)
    end
  end

  describe "#for with the fourth slot" do
    it "carries the fourth kind and its own reinforcement, due_checks, and established when one is chosen" do
      pin_kind("plan_review")
      result = DailyPlan.for(user, language: "ruby_rails")

      expect(%i[plan_review ambiguity_hunt]).to include(result.fourth)
      expect(result.fourth_reinforcement).to eq([])
      expect(result.fourth_due_checks).to eq([])
      expect(result.fourth_established).to eq([])
    end

    it "excludes fourth-slot buckets from the non-fourth reinforcement pool" do
      exercise = DailyExercise.create!(user: user, date: Date.current - 1, generated_at: Time.current,
                                       problem_set: { "plan_review" => { "concept" => "scope_creep" } })
      DailyResponse.create!(user: user, daily_exercise: exercise, date: exercise.date, submitted_at: Time.current,
                            answers: { "plan_review" => "x" * 20 },
                            section_ratings: { "plan_review" => "too_hard" },
                            concept_tags: { "plan_review" => "scope_creep" },
                            ai_review: { "plan_review" => { "rating" => "developing" } })

      # scope_creep is a plan_review concept, so the fourth roll is pinned to plan_review.
      pin_kind("plan_review")

      result = DailyPlan.for(user, language: "ruby_rails")
      expect(result.reinforcement.map { |h| h[:concept] }).not_to include("scope_creep")
      expect(result.fourth_reinforcement.map { |h| h[:concept] }).to include("scope_creep")
    end

    it "reserves the fourth slot's single slot for retention only once meaningfully overdue" do
      user.concept_masteries.create!(concept: "scope_creep", language: "plan_review", tier: :standard,
                                     mastered_at: 1.month.ago, retention_interval_days: 7,
                                     next_retention_check_on: Date.current - 1)
      allow(user).to receive(:concepts_needing_reinforcement).and_call_original
      allow(user).to receive(:concepts_needing_reinforcement).with(bucket: "plan_review", hostable: anything)
        .and_return([ { concept: "unjustified_constant", bucket: "plan_review", tier: "standard" } ])
      pin_kind("plan_review")

      result = DailyPlan.for(user, language: "ruby_rails")
      expect(result.fourth_due_checks).to eq([])

      user.concept_masteries.find_by(concept: "scope_creep").update!(next_retention_check_on: Date.current - 10)
      result = DailyPlan.for(user, language: "ruby_rails")
      expect(result.fourth_due_checks.map(&:concept)).to eq(%w[scope_creep])
    end

    it "caps fourth-slot reinforcement at the slot's single capacity" do
      allow(user).to receive(:concepts_needing_reinforcement).and_call_original
      allow(user).to receive(:concepts_needing_reinforcement).with(bucket: "plan_review", hostable: anything)
        .and_return([ { concept: "scope_creep", bucket: "plan_review", tier: "standard" },
                      { concept: "unjustified_constant", bucket: "plan_review", tier: "standard" },
                      { concept: "unflagged_behavior_change", bucket: "plan_review", tier: "standard" } ])
      pin_kind("plan_review")

      result = DailyPlan.for(user, language: "ruby_rails")

      expect(result.fourth_reinforcement.size).to eq(DailyPlan::FOURTH_SLOT_CAPACITY)
      expect(result.fourth_reinforcement.map { |h| h[:concept] }).to eq(%w[scope_creep])
    end

    it "drops fourth-slot reinforcement entirely when an overdue retention check takes the slot" do
      user.concept_masteries.create!(concept: "scope_creep", language: "plan_review", tier: :standard,
                                     mastered_at: 1.month.ago, retention_interval_days: 7,
                                     next_retention_check_on: Date.current - 10)
      allow(user).to receive(:concepts_needing_reinforcement).and_call_original
      allow(user).to receive(:concepts_needing_reinforcement).with(bucket: "plan_review", hostable: anything)
        .and_return([ { concept: "unjustified_constant", bucket: "plan_review", tier: "standard" } ])
      pin_kind("plan_review")

      result = DailyPlan.for(user, language: "ruby_rails")

      expect(result.fourth_due_checks.map(&:concept)).to eq(%w[scope_creep])
      expect(result.fourth_reinforcement).to eq([])
    end
  end

  describe "CODE_REVIEW_MODE_WEIGHTS" do
    it "splits a weekday three ways as decided, summing to 1.0, with no bug_hunt" do
      expect(DailyPlan::CODE_REVIEW_MODE_WEIGHTS).to eq(application_code: 0.30, test_file: 0.29, schema_review: 0.41)
      expect(DailyPlan::CODE_REVIEW_MODE_WEIGHTS.values.sum).to be_within(0.001).of(1.0)
    end

    it "reaches every weekday mode" do
      allow(WeightedRoll).to receive(:pick).and_call_original
      { 0.0 => :application_code, 0.30 => :test_file, 0.59 => :schema_review }.each do |value, expected|
        allow(WeightedRoll).to receive(:rand).and_return(value)
        expect(WeightedRoll.pick(DailyPlan::CODE_REVIEW_MODE_WEIGHTS)).to eq(expected)
      end
    end

    it "makes every weekend code review a bug_hunt, and lists every mode once" do
      allow(WeightedRoll).to receive(:pick).and_call_original

      expect(WeightedRoll.pick(DailyPlan::WEEKEND_CODE_REVIEW_MODE_WEIGHTS)).to eq(:bug_hunt)
      expect(DailyPlan::CODE_REVIEW_MODES).to contain_exactly(:application_code, :test_file, :schema_review, :bug_hunt)
    end
  end

  describe "SCENARIO_FLAVOR_WEIGHTS" do
    it "is exactly half everyday and half job-adjacent" do
      expect(DailyPlan::SCENARIO_FLAVOR_WEIGHTS).to eq(everyday: 0.5, general: 0.5)
    end

    it "reaches both flavors" do
      { 0.0 => :everyday, 0.5 => :general }.each do |value, expected|
        allow(WeightedRoll).to receive(:rand).and_return(value)
        expect(WeightedRoll.pick(DailyPlan::SCENARIO_FLAVOR_WEIGHTS)).to eq(expected)
      end
    end
  end

  describe "#scenario_flavor on the plan" do
    let(:user) { User.create!(email: "plan@example.com") }

    it "rolls every skill level from the same weights" do
      allow(WeightedRoll).to receive(:pick).and_call_original
      allow(WeightedRoll).to receive(:pick).with(DailyPlan::SCENARIO_FLAVOR_WEIGHTS).and_return(:everyday)

      User::SKILL_LEVELS.each do |level|
        user.update!(skill_level: level)
        expect(DailyPlan.for(user, language: "ruby_rails").scenario_flavor).to eq(:everyday)
      end
    end

    it "is carried on the Result from its own roll, on any language" do
      allow(WeightedRoll).to receive(:pick).with(DailyPlan::SCENARIO_FLAVOR_WEIGHTS).and_return(:general)

      expect(DailyPlan.for(user, language: "ruby_rails").scenario_flavor).to eq(:general)
      expect(DailyPlan.for(user, language: "javascript").scenario_flavor).to eq(:general)
    end
  end

  describe "#code_review_mode on the plan" do
    let(:user) { User.create!(email: "plan@example.com") }

    it "is carried on the Result" do
      allow(WeightedRoll).to receive(:rand).and_return(0.67)
      expect(DailyPlan.for(user, language: "ruby_rails").code_review_mode).to eq(:schema_review)
    end
  end

  describe "delivery of Authentic PR Review" do
    let(:plan) { plan_for(code_review_mode: :application_code, code_review_files: :single) }
    let(:rungs) { { "code_review" => "mid_level" } }

    def choose_variant(candidate = plan, language: "ruby_rails", kind_rungs: rungs)
      candidate.select_delivery_variant(language: language, kind_rungs: kind_rungs)
    end

    it "delegates delivery selection to the kinds included in the plan" do
      pattern = ExerciseSection::Pattern
      candidate = plan.with(selected_kinds: [ pattern ])
      selected = candidate.with(scenario_flavor: :everyday)
      expect(pattern).to receive(:select_delivery_variant).with(plan: candidate, language: "ruby_rails", rung: "junior")
        .and_return(selected)

      expect(choose_variant(candidate, kind_rungs: { "pattern" => "junior" })).to equal(selected)
    end

    it "can select either hidden case for an eligible generated day without changing its sections or notes" do
      weights = { "ordinary" => 0.60, "acceptable" => 0.20, "flawed" => 0.20 }
      %w[acceptable flawed].each do |target|
        allow(WeightedRoll).to receive(:pick).with(weights).and_return(target)

        variant = choose_variant
        expect(variant).to have_attributes(code_review_mode: :pr_review, code_review_files: :multi, pr_review_target: target)
        expect(variant.kinds).to eq(plan.kinds)
        expect(variant.notes).to eq(plan.notes)
        expect(choose_variant(variant)).to equal(variant)
      end
    end

    it "leaves the original plan in place when the ordinary outcome is drawn" do
      allow(WeightedRoll).to receive(:pick).with({ "ordinary" => 0.60, "acceptable" => 0.20, "flawed" => 0.20 }).and_return("ordinary")

      expect(choose_variant).to equal(plan)
    end

    it "skips other languages, rungs, existing modes, curated sources and sets without Code Review" do
      expect(WeightedRoll).not_to receive(:pick)

      expect(choose_variant(language: "javascript")).to equal(plan)
      %w[junior senior principal_engineer].each do |rung|
        expect(choose_variant(kind_rungs: { "code_review" => rung })).to equal(plan)
      end
      [
        plan.with(code_review_mode: :schema_review), plan.with(code_review_mode: :test_file), plan.with(code_review_mode: :bug_hunt),
        plan.with(code_review_source: RealSource::APPLICATION_CODE.first), plan.with(selected_kinds: [ ExerciseSection::Pattern ])
      ].each { |other| expect(choose_variant(other)).to equal(other) }
    end
  end

  describe "#code_review_source on the plan" do
    let(:user) { User.create!(email: "source@example.com") }

    def plan(language: "ruby_rails", mode: :application_code, roll: :real)
      pin_code_review_mode(mode)
      allow(WeightedRoll).to receive(:pick).with(RealSource::WEIGHTS).and_return(roll)
      DailyPlan.for(user, language: language)
    end

    it "is an excerpt from the mode's own pool when the roll lands real" do
      expect(RealSource::APPLICATION_CODE).to include(plan.code_review_source)
      expect(RealSource::SCHEMA_REVIEW).to include(plan(mode: :schema_review).code_review_source)
    end

    it "is nil when the roll lands toy" do
      expect(plan(roll: :toy).code_review_source).to be_nil
    end

    it "keeps the suite-wide toy pin when only the mode is pinned" do
      allow(WeightedRoll).to receive(:rand).and_return(0.1)
      pin_code_review_mode(:application_code)

      expect(DailyPlan.for(user, language: "ruby_rails").code_review_source).to be_nil
    end

    it "is nil on a javascript day even when the roll lands real" do
      expect(plan(language: "javascript").code_review_source).to be_nil
    end

    it "is nil on a test_file day, which has no pool" do
      expect(plan(mode: :test_file).code_review_source).to be_nil
    end

    it "never rolls at all when the gate closes" do
      expect(WeightedRoll).not_to receive(:pick).with(RealSource::WEIGHTS)
      pin_code_review_mode(:test_file)

      DailyPlan.for(user, language: "ruby_rails")
    end

    it "prefers what this user has not seen, reading the stamped trace" do
      first = RealSource::APPLICATION_CODE.first
      user.daily_exercises.create!(date: Date.current - 1, generated_at: Time.current, language: "ruby_rails",
                                   problem_set: { "code_review" => { "source" => first.id } })

      expect(plan.code_review_source).to eq(RealSource::APPLICATION_CODE.second)
    end
  end

  describe "#code_review_files on the plan" do
    let(:user) { User.create!(email: "files@example.com") }

    def plan(source_roll: :toy, files_roll: :multi)
      pin_code_review_mode(:application_code)
      allow(WeightedRoll).to receive(:pick).with(RealSource::WEIGHTS).and_return(source_roll)
      allow(WeightedRoll).to receive(:pick).with(DailyPlan::CODE_REVIEW_FILE_WEIGHTS).and_return(files_roll)
      DailyPlan.for(user, language: "ruby_rails")
    end

    it "rolls multi-file on a quarter of the days that can show files" do
      expect(DailyPlan::CODE_REVIEW_FILE_WEIGHTS).to eq(single: 0.75, multi: 0.25)
    end

    it "carries the files roll on a toy day" do
      expect(plan.code_review_files).to eq(:multi)
      expect(plan(files_roll: :single).code_review_files).to eq(:single)
    end

    it "is single, without rolling, on a day grounded in a real excerpt" do
      expect(WeightedRoll).not_to receive(:pick).with(DailyPlan::CODE_REVIEW_FILE_WEIGHTS)

      grounded = plan(source_roll: :real)

      expect(grounded.code_review_source).to be_present
      expect(grounded.code_review_files).to eq(:single)
    end
  end

  describe "a bug_hunt day" do
    before { pin_kind("code_review") }
    let(:user) { User.create!(email: "hunt-plan@example.com") }

    def plan(language: "ruby_rails", featured_concept: nil)
      allow(WeightedRoll).to receive(:pick).and_call_original
      pin_code_review_mode(:bug_hunt)
      DailyPlan.for(user, language: language, featured_concept: featured_concept)
    end

    def roll_on(time, **options)
      allow(WeightedRoll).to receive(:pick).and_call_original
      travel_to(time) { DailyPlan.for(user, language: "ruby_rails", **options) }
    end

    def expect_rolled(weights, not_rolled)
      expect(WeightedRoll).to have_received(:pick).with(weights)
      expect(WeightedRoll).not_to have_received(:pick).with(not_rolled)
    end

    it "rolls the weekday weights, which hold no bug_hunt, on a weekday" do
      roll_on(Time.zone.local(2026, 10, 16, 9))

      expect_rolled(DailyPlan::CODE_REVIEW_MODE_WEIGHTS, DailyPlan::WEEKEND_CODE_REVIEW_MODE_WEIGHTS)
    end

    [ Time.zone.local(2026, 10, 17, 9), Time.zone.local(2026, 10, 18, 9) ].each do |time|
      it "makes the code review a bug_hunt on a #{time.strftime("%A")}" do
        roll_on(time)

        expect_rolled(DailyPlan::WEEKEND_CODE_REVIEW_MODE_WEIGHTS, DailyPlan::CODE_REVIEW_MODE_WEIGHTS)
      end
    end

    it "plans a bug_hunt on a Saturday with the real weekend roll, not the suite's weekday stand-in" do
      allow(WeightedRoll).to receive(:pick).and_call_original

      plan = travel_to(Time.zone.local(2026, 10, 17, 9)) { DailyPlan.for(user, language: "ruby_rails") }

      expect(plan.code_review_mode).to eq(:bug_hunt)
      expect(plan.code_review_gotcha).to be_present
    end

    it "plans a weekday set on a weekend when the caller asks for one, as the measurement scripts do" do
      roll_on(Time.zone.local(2026, 10, 17, 9), weekend: false)

      expect_rolled(DailyPlan::CODE_REVIEW_MODE_WEIGHTS, DailyPlan::WEEKEND_CODE_REVIEW_MODE_WEIGHTS)
    end

    it "is single-file without rolling, and grounded in no real excerpt" do
      expect(WeightedRoll).not_to receive(:pick).with(DailyPlan::CODE_REVIEW_FILE_WEIGHTS)
      expect(WeightedRoll).not_to receive(:pick).with(RealSource::WEIGHTS)

      result = plan

      expect(result.code_review_files).to eq(:single)
      expect(result.code_review_source).to be_nil
    end

    it "picks the language's first gotcha never seen, and records its id in the notes" do
      seen = BugHuntGotchas.for_language("javascript").first
      user.daily_exercises.create!(date: Date.current - 1, generated_at: Time.current, language: "javascript",
                                   problem_set: { "code_review" => { "purpose" => "Sum the totals." } },
                                   plan_notes: { "bug_hunt" => seen.id })

      result = plan(language: "javascript")

      expect(result.code_review_gotcha).to eq(BugHuntGotchas.for_language("javascript").second)
      expect(result.notes["bug_hunt"]).to eq(result.code_review_gotcha.id)
    end

    it "skips the week's featured concept when it picks the gotcha, and carries the featured concept on the plan" do
      first = BugHuntGotchas.for_language("ruby_rails").first
      result = plan(featured_concept: first.concept)

      expect(result.code_review_gotcha.concept).not_to eq(first.concept)
      expect(result.code_review_gotcha).to eq(BugHuntGotchas.for_language("ruby_rails").find { |entry| entry.concept != first.concept })
      expect(result.featured_concept).to eq(first.concept)
    end

    it "skips the concept by name for a mixed-language user whose Ruby week features a concept JavaScript teaches too" do
      shared = (BugHuntGotchas.concepts("ruby_rails") & BugHuntGotchas.concepts("javascript")).first
      user.update!(language: "mixed")

      result = plan(language: "javascript", featured_concept: shared)

      expect(BugHuntGotchas.for_language("javascript").first.concept).to eq(shared)
      expect(result.code_review_gotcha.concept).not_to eq(shared)
    end

    it "carries no featured concept unless one is passed" do
      expect(plan.featured_concept).to be_nil
    end

    it "picks no gotcha on a day without a code_review section" do
      user.update!(daily_section_count: 1, daily_section_kinds: %w[design_comparison code_review])
      pin_kind("design_comparison")

      result = plan

      expect(result.kinds).not_to include(ExerciseSection::CodeReview)
      expect(result.code_review_gotcha).to be_nil
      expect(result.notes).not_to have_key("bug_hunt")
    end

    it "withholds no concept from the other sections on a day without a code_review section" do
      user.update!(daily_section_count: 1, daily_section_kinds: %w[design_comparison code_review])
      pin_kind("design_comparison")
      trap = BugHuntGotchas.find("rb_memo_falsy")
      allow(BugHuntGotchas).to receive(:pick).and_return(trap)

      result = plan
      hosts = DayHosts.new("ruby_rails", mode: result.code_review_mode, gotcha: result.code_review_gotcha,
        featured_concept: result.featured_concept)

      expect(hosts.can_tag?(ExerciseSection::DesignComparison, trap.concept, "ruby_rails")).to be(true)
    end

    it "picks no gotcha on any other mode" do
      pin_code_review_mode(:application_code)

      result = DailyPlan.for(user, language: "ruby_rails")

      expect(result.code_review_gotcha).to be_nil
      expect(result.notes).not_to have_key("bug_hunt")
    end

    it "plans no retention check onto code_review, and leaves one only code_review could take waiting" do
      user.concept_masteries.create!(concept: "error_handling", language: "ruby_rails", tier: :standard,
                                     mastered_at: 1.month.ago, retention_interval_days: 7,
                                     next_retention_check_on: Date.current - 1)
      pin_kind("code_review")

      hunt = plan

      expect(hunt.due_checks).to eq([])
      expect(hunt.waiting_checks).to include(a_hash_including(concept: "error_handling", reason: :no_host))

      pin_code_review_mode(:application_code)
      expect(DailyPlan.for(user, language: "ruby_rails").due_checks.map(&:concept)).to eq([ "error_handling" ])
    end

    it "plans no reinforcement onto code_review" do
      allow(user).to receive(:concepts_needing_reinforcement).and_wrap_original do |original, **options|
        original.call(**options)
        [ { concept: "error_handling", bucket: "ruby_rails", tier: "standard" } ].select do |entry|
          options[:hostable].nil? || options[:hostable].call(entry[:concept], entry[:bucket])
        end
      end
      pin_kind("code_review")

      expect(plan.reinforcement).to eq([])
    end

    it "plans no retention check on the picked trap's concept onto another section" do
      concept = BugHuntGotchas.for_language("ruby_rails").first.concept
      user.concept_masteries.create!(concept: concept, language: "ruby_rails", tier: :standard,
                                     mastered_at: 1.month.ago, retention_interval_days: 7,
                                     next_retention_check_on: Date.current - 1)
      pin_kind("code_review")

      hunt = plan

      expect(hunt.code_review_gotcha.concept).to eq(concept)
      expect(hunt.due_checks).to eq([])
      expect(hunt.waiting_checks).to include(a_hash_including(concept: concept, reason: :no_host))
    end

    it "picks no shared concept, which design_comparison's reference would name before submission" do
      allow(SharedConcept).to receive(:pick).and_call_original
      pin_kind("code_review")

      expect(plan.shared_concept).to be_nil
    end

    it "copes with a day whose only section is code_review" do
      user.update!(daily_section_count: 1)

      result = plan

      expect(result.reinforcement).to eq([])
      expect(result.due_checks).to eq([])
    end
  end

  describe "stated rotation preferences" do
    it "hands the user's stated preferences to single-slot selection" do
      user = create_fake_provider_user
      user.update!(excluded_section_kinds: [ "parsons_problem" ])

      allow(PracticeSchedule).to receive(:single_turn).and_call_original

      described_class.for(user, language: "ruby_rails")

      expect(PracticeSchedule).to have_received(:single_turn) do |**options|
        preferences, daily = options.values_at(:preferences, :daily)
        expect(daily).to eq(DailyKinds::DEFAULT)
        expect(preferences.excluded?(ExerciseSection::ParsonsProblem)).to be(true)
      end
    end
  end

  describe "difficulty targets" do
    it "never reads KindDifficulty and plans the same day regardless" do
      pin_kind("plan_review")
      pin_code_review_mode(:application_code)
      allow(WeightedRoll).to receive(:pick).with(DailyPlan::SCENARIO_FLAVOR_WEIGHTS).and_return(:general)
      expect(KindDifficulty).not_to receive(:for)
      expect(KindDifficulty).not_to receive(:new)

      untargeted = DailyPlan.for(user, language: "ruby_rails")
      user.update_columns(section_kind_levels: { "code_review" => "senior", "challenge" => "junior" })
      targeted = DailyPlan.for(user.reload, language: "ruby_rails")
      user.update_columns(locked_section_kinds: [ "code_review", "challenge" ])
      locked = DailyPlan.for(user.reload, language: "ruby_rails")

      expect(targeted).to eq(untargeted)
      expect(locked).to eq(untargeted)
    end
  end
end

RSpec.describe DailyPlan, "drilled concepts" do
  include DailyPlanSelectionStubs
  let(:user) { User.create!(email: "plan-drill@example.com") }

  def submit(concept, section: "code_review", date:)
    exercise = DailyExercise.create!(user: user, date: date, generated_at: Time.current, language: "ruby_rails",
                                     problem_set: { section => { "concept" => concept } })
    DailyResponse.create!(user: user, daily_exercise: exercise, date: date, submitted_at: Time.current,
                          answers: { section => "x" * 20 }, section_ratings: { section => "too_hard" },
                          concept_tags: { section => concept }, ai_review: { section => { "rating" => "developing" } })
  end

  it "keeps drilled concepts when truncating reinforcement to today's hosts" do
    pin_code_review_mode(:application_code)
    submit("n_plus_one", date: Date.current - 1)
    submit("transaction_safety", date: Date.current - 2)
    ConceptDrills.start!(user, concept: "memoization", bucket: "ruby_rails")
    pin_kind("code_review")

    plan = described_class.for(user, language: "ruby_rails")

    expect(plan.reinforcement).to eq([
      { concept: "memoization", bucket: "ruby_rails", tier: "standard", drilled: true }
    ])
  end

  it "offers a drilled architecture concept only on a day with an architecture section" do
    ConceptDrills.start!(user, concept: "sync_vs_async", bucket: "architecture")

    pin_kind("challenge")
    expect(described_class.for(user, language: "ruby_rails").reinforcement).to eq([])

    pin_kind("architecture")
    expect(described_class.for(user, language: "ruby_rails").reinforcement.map { |h| h[:concept] }).to eq(%w[sync_vs_async])
  end

  it "offers a drilled data-modeling concept only when a section today can tag it" do
    ConceptDrills.start!(user, concept: "denormalization_tradeoffs", bucket: "ruby_rails")
    pin_kind("code_review")

    pin_code_review_mode(:application_code)
    expect(described_class.for(user, language: "ruby_rails").reinforcement).to eq([])

    pin_code_review_mode(:schema_review)
    expect(described_class.for(user, language: "ruby_rails").reinforcement.map { |h| h[:concept] })
      .to eq(%w[denormalization_tradeoffs])
  end

  it "offers only one drill without consuming the remaining group or reinforcement" do
    submit("n_plus_one", date: Date.current - 1)
    ConceptDrills.start_group!(user, group: "data_modeling", bucket: "ruby_rails")
    pin_kind("challenge")

    plan = described_class.for(user, language: "ruby_rails")

    expect(plan.reinforcement.size).to eq(1)
    expect(plan.reinforcement.first).to include(drilled: true)
    expect(user.concepts_needing_reinforcement.map { |entry| entry[:concept] }).to include("n_plus_one")
  end

  it "retains evidence waiting while the one legacy host serves a drill" do
    submit("n_plus_one", date: Date.current - 1)
    ConceptDrills.start!(user, concept: "memoization", bucket: "ruby_rails")
    pin_kind("code_review")
    pin_code_review_mode(:application_code)

    plan = described_class.for(user, language: "ruby_rails")

    expect(plan.reinforcement.map { |h| h[:concept] }).to eq(%w[memoization])
    expect(user.concepts_needing_reinforcement.map { |entry| entry[:concept] }).to include("n_plus_one")
  end

  it "holds no host back from a drill for evidence today cannot host" do
    submit("reading_for_intent", date: Date.current - 1)
    ConceptDrills.start_group!(user, group: "data_modeling", bucket: "ruby_rails")
    pin_kind("code_review")
    pin_code_review_mode(:schema_review)

    plan = described_class.for(user, language: "ruby_rails")

    expect(plan.reinforcement.map { |h| h[:concept] }).not_to include("reading_for_intent")
    expect(plan.reinforcement.size).to eq(1)
    expect(plan.reinforcement).to all(include(drilled: true))
  end

  it "still gives a one-host share to the drill with evidence waiting" do
    drilled  = { concept: "memoization", bucket: "ruby_rails", tier: "standard", drilled: true }
    evidence = { concept: "n_plus_one", bucket: "ruby_rails", tier: "standard" }

    expect(described_class.send(:share_hosts, [ drilled, evidence ], 1)).to eq([ drilled ])
  end

  it "does not let a drilled concept's own overdue check take the slot back from it" do
    ConceptDrills.start!(user, concept: "memoization", bucket: "ruby_rails")
    user.concept_masteries.find_by(concept: "memoization").update!(
      mastered_at: 1.month.ago, retention_interval_days: 7, next_retention_check_on: Date.current - 20
    )
    pin_kind("code_review")
    pin_code_review_mode(:application_code)

    plan = described_class.for(user, language: "ruby_rails")

    expect(plan.reinforcement.map { |h| h[:concept] }).to eq(%w[memoization])
    expect(plan.due_checks).to eq([])
  end

  it "lists a drilled concept whose retention check is due once, as reinforcement" do
    ConceptDrills.start!(user, concept: "memoization", bucket: "ruby_rails")
    user.concept_masteries.find_by(concept: "memoization").update!(
      mastered_at: 1.month.ago, retention_interval_days: 7, next_retention_check_on: Date.current - 20
    )
    pin_kind("challenge")

    plan = described_class.for(user, language: "ruby_rails")

    expect(plan.reinforcement.map { |h| h[:concept] }).to eq(%w[memoization])
    expect(plan.due_checks).to eq([])
  end

  it "gives a drilled fourth-bucket concept the fourth slot" do
    submit("scope_creep", section: "plan_review", date: Date.current - 1)
    ConceptDrills.start!(user, concept: "unjustified_constant", bucket: "plan_review")
    pin_kind("plan_review")

    plan = described_class.for(user, language: "ruby_rails")

    expect(plan.fourth_reinforcement).to eq([ { concept: "unjustified_constant", bucket: "plan_review", tier: "standard", drilled: true } ])
    expect(plan.reinforcement).to eq([])
  end

  it "keeps a drilled fourth concept out of the fourth retention checks" do
    ConceptDrills.start!(user, concept: "unjustified_constant", bucket: "plan_review")
    user.concept_masteries.find_by(concept: "unjustified_constant").update!(
      mastered_at: 1.month.ago, retention_interval_days: 7, next_retention_check_on: Date.current - 20
    )
    pin_kind("plan_review")

    plan = described_class.for(user, language: "ruby_rails")

    expect(plan.fourth_reinforcement.map { |h| h[:concept] }).to eq(%w[unjustified_constant])
    expect(plan.fourth_due_checks).to eq([])
  end
end

RSpec.describe DailyPlan, "same-named concepts across language buckets" do
  include DailyPlanSelectionStubs
  let(:user) { User.create!(email: "plan-mixed@example.com", language: "mixed") }

  it "lets a ruby retention check stand when only the javascript occurrence is in reinforcement" do
    exercise = user.daily_exercises.create!(date: Date.current - 1, generated_at: Time.current, language: "javascript",
      problem_set: { "code_review" => { "concept" => "over_mocking" } })
    user.daily_responses.create!(daily_exercise: exercise, date: exercise.date, submitted_at: Time.current,
      answers: { "code_review" => "x" * 20 }, section_ratings: { "code_review" => "too_hard" },
      concept_tags: { "code_review" => "over_mocking" }, ai_review: { "code_review" => { "rating" => "developing" } })
    user.concept_masteries.create!(concept: "over_mocking", language: "ruby_rails", tier: :standard,
                                   mastered_at: 1.month.ago, retention_interval_days: 7, next_retention_check_on: Date.current - 20)
    pin_kind("challenge")

    plan = described_class.for(user, language: "ruby_rails")

    expect(plan.reinforcement).to eq([])
    expect(plan.due_checks.map { |cm| [ cm.concept, cm.language ] }).to eq([ [ "over_mocking", "ruby_rails" ] ])

    on_javascript_day = described_class.for(user, language: "javascript")

    expect(on_javascript_day.reinforcement).to eq([ { concept: "over_mocking", bucket: "javascript", tier: "standard" } ])
    expect(on_javascript_day.due_checks).to eq([])
  end
end

RSpec.describe DailyPlan::Result, "#notes" do
  def result(**overrides)
    defaults = DailyPlan::Result.members.index_with { nil }.merge(daily_kinds: DailyKinds::DEFAULT, code_review_files: :single)
    DailyPlan::Result.new(**defaults, **overrides)
  end

  let(:pair) { { "daily_kinds" => %w[code_review design_comparison] } }

  it "always records the pair, and otherwise only what applied" do
    expect(result.notes).to eq(pair)
    expect(result(shared_concept: "feature_envy").notes).to eq(pair.merge("shared_concept" => "feature_envy"))
    gap = CoverageException::Addition.new(kind: ExerciseSection::Pattern, reason: :gap)
    expect(result(coverage: gap).notes).to eq(pair.merge("coverage" => "pattern", "coverage_reason" => "gap"))
  end

  it "records the day's daily kinds by key, in place order" do
    daily = [ ExerciseSection::Architecture, ExerciseSection::CodeReview ]

    expect(result(daily_kinds: daily).notes).to eq("daily_kinds" => %w[architecture code_review])
    expect(DailyKinds.recorded(result(daily_kinds: daily).notes)).to eq(daily)
  end

  it "records the planned size beside a coverage addition" do
    size = DaySize.for(setting: nil, gate: CompetencyGate::Plan.new(count: 2, reason: :held, safety_hold: false, evidence: {}))
    gap = CoverageException::Addition.new(kind: ExerciseSection::Pattern, reason: :gap)

    expect(result(size: size, coverage: gap).notes)
      .to eq(pair.merge("size" => 2, "size_reason" => "gate", "coverage" => "pattern", "coverage_reason" => "gap"))
  end
end

RSpec.describe DailyPlan, "retention checks left waiting" do
  include DailyPlanSelectionStubs

  let(:user) { User.create!(email: "plan-waiting@example.com") }

  before do
    pin_code_review_mode(:application_code)
    pin_kind("challenge")
  end

  def due(concept, bucket, days_late: 2)
    user.concept_masteries.create!(concept: concept, language: bucket, tier: :standard, mastered_at: 2.months.ago,
                                   retention_interval_days: 7, next_retention_check_on: Date.current - days_late)
  end

  def waiting
    described_class.for(user, language: "ruby_rails").waiting_checks.map { |w| w.slice(:bucket, :concept, :reason) }
  end

  it "names an architecture check and a fourth-bucket check no section today can tag" do
    due("service_boundaries", "architecture")
    due("scope_creep", "plan_review")

    expect(waiting).to contain_exactly(
      { bucket: "architecture", concept: "service_boundaries", reason: :no_host },
      { bucket: "plan_review", concept: "scope_creep", reason: :no_host }
    )
  end

  it "gives the featured fourth-bucket concept no host, so its due check waits where it would have been planned" do
    user.update!(daily_section_count: ExerciseSection::MAX_SECTIONS)
    pin_kind("plan_review")
    due("scope_creep", "plan_review")
    featured = "scope_creep"

    unfeatured = described_class.for(user, language: "ruby_rails")
    held_back  = described_class.for(user, language: "ruby_rails", featured_concept: featured)

    expect(unfeatured.fourth_due_checks.map(&:concept)).to eq(%w[scope_creep])
    expect(held_back.fourth_due_checks).to eq([])
    expect(held_back.waiting_checks.map { |w| w.slice(:bucket, :concept, :reason) })
      .to eq([ { bucket: "plan_review", concept: "scope_creep", reason: :no_host } ])
  end

  it "marks a check the featured concept held back, and only that one" do
    user.update!(daily_section_count: ExerciseSection::MAX_SECTIONS)
    pin_kind("plan_review")
    due("scope_creep", "plan_review")
    due("service_boundaries", "architecture")

    held_back = described_class.for(user, language: "ruby_rails", featured_concept: "scope_creep")

    expect(held_back.waiting_checks.to_h { |w| [ w[:concept], w[:held_by_featured] ] })
      .to eq("scope_creep" => true, "service_boundaries" => nil)
  end

  it "does not mark a featured concept's check that would have had no host anyway" do
    pin_kind("code_review")
    due("scope_creep", "plan_review")

    plan = described_class.for(user, language: "ruby_rails", featured_concept: "scope_creep")

    expect(plan.waiting_checks).to contain_exactly(a_hash_including(concept: "scope_creep", reason: :no_host))
    expect(plan.waiting_checks.first).not_to have_key(:held_by_featured)
  end

  it "says no_slot when a section could tag the check but reinforcement took every host" do
    allow(user).to receive(:concepts_needing_reinforcement).and_return(
      %w[n_plus_one service_objects query_objects policy_objects].map { |c| { concept: c, bucket: "ruby_rails", tier: "standard" } }
    )
    due("memoization", "ruby_rails")

    expect(waiting).to eq([ { bucket: "ruby_rails", concept: "memoization", reason: :no_slot } ])
  end

  it "leaves out the concept served as reinforcement and retains another due check" do
    allow(user).to receive(:concepts_needing_reinforcement)
      .and_return([ { concept: "n_plus_one", bucket: "ruby_rails", tier: "standard" } ])
    due("memoization", "ruby_rails")
    due("n_plus_one", "ruby_rails")

    plan = described_class.for(user, language: "ruby_rails")

    expect(plan.due_checks).to be_empty
    expect(plan.waiting_checks).to contain_exactly(include(concept: "memoization", reason: :no_slot))
  end

  it "names the other language's check for a mixed user as having no host today" do
    user.update!(language: "mixed")
    due("closures", "javascript")

    expect(waiting).to eq([ { bucket: "javascript", concept: "closures", reason: :no_host } ])
  end

  it "offers the generated language's check when the user's setting has moved to the other language" do
    user.update!(language: "javascript")
    due("memoization", "ruby_rails")

    plan = described_class.for(user, language: "ruby_rails")

    expect(plan.due_checks.map(&:concept)).to eq(%w[memoization])
    expect(plan.waiting_checks).to eq([])
  end

  it "lists the most overdue first" do
    due("service_boundaries", "architecture", days_late: 2)
    due("scope_creep", "plan_review", days_late: 20)

    expect(waiting.map { |w| w[:concept] }).to eq(%w[scope_creep service_boundaries])
  end
end

RSpec.describe DailyPlan, "protected weekend variety hosts" do
  include DailyPlanSelectionStubs
  let(:pair) { %w[pattern design_comparison] }
  let(:replacement) { "code_review" }
  let(:user) { User.create!(email: "weekend-variety@example.com", daily_section_kinds: pair, daily_section_count: nil) }
  let(:trap) { BugHuntGotchas.find("rb_memo_falsy") }
  let(:requests) { { "pattern" => { "mode" => "normal_retry", "source_response_id" => 17, "requested_at" => "2026-11-06T12:00:00.123456Z" } } }
  let(:mastery) do
    user.concept_masteries.create!(concept: trap.concept, language: "ruby_rails", tier: :standard,
      mastered_at: 1.month.ago, retention_interval_days: 7, next_retention_check_on: Date.yesterday, practice_requests: requests)
  end
  let(:note) do
    daily = DailyKinds.for(user)
    pool = ExerciseSection.optional_slots(daily: daily).values.flatten.map(&:key)
    PracticeSchedule::Note.decode({
      "version" => 1, "policy" => 2, "sequence" => 3, "initial_ready" => true,
      "regular_kinds" => pair, "selected_kinds" => pair, "phase" => 2, "assignments" => {},
      "continuation" => { "next_phase" => 0, "kind_order" => [ replacement ] + (pool - [ replacement ]),
        "next_kind_index" => 0, "last_omitted_kind" => nil, "service" => {
          "pattern" => { "last_lane" => "maintenance", "last_maintenance" => "drill",
            "concepts" => [ { "concept" => trap.concept, "bucket" => "ruby_rails", "sequence" => 1 } ] }
        } }
    })
  end

  around { |example| travel_to(Time.zone.local(2026, 11, 7, 9)) { example.run } }

  before do
    mastery
    pin_code_review_mode(:bug_hunt)
    expect(BugHuntGotchas).to receive(:pick).once.and_return(trap)
    pin_kind(replacement)
    expect(PracticeSchedule::SingleSlot).to receive(:plan).once.and_call_original
  end

  def weekend_plan(replacing: false)
    previous = note.deep_dup
    if replacing
      previous.merge!("selected_kinds" => [ pair.first, replacement ], "omitted_kind" => pair.last, "phase" => 0)
      previous["continuation"].merge!("next_phase" => 1, "next_kind_index" => 1, "last_omitted_kind" => pair.last)
    end
    exercise = user.daily_exercises.create!(date: Date.current, generated_at: Time.current,
      problem_set: previous["selected_kinds"].index_with { { "question" => "Explain the choice." } },
      plan_notes: { "daily_kinds" => pair, "practice_schedule" => previous })
    context = PracticeGeneration.capture(user, date: Date.current, replacing: (exercise if replacing))
    plan = described_class.for(user, language: "ruby_rails", schedule_context: context)
    expect(context.fetch(:active)).to be(true)
    expect(user.daily_section_count).to be_nil
    expect(plan.size.count).to eq(1)
    expect(plan.kinds.map(&:key)).to eq([ replacement ])
    expect(plan.daily_kinds.map(&:key)).to eq(pair)
    expect(plan.code_review_mode).to eq(:bug_hunt)
    expect(plan.coverage).to be_nil
    final_hosts = DayHosts.new("ruby_rails", mode: plan.code_review_mode, gotcha: plan.code_review_gotcha,
      featured_concept: plan.featured_concept)
    plan.assignments.each do |key, entry|
      expect(final_hosts.can_tag?(ExerciseSection.for(key), entry[:concept], entry[:bucket])).to be(true)
    end
    expect(mastery.reload.practice_requests).to eq(requests)
    if replacing
      expect(plan.practice_schedule["sequence"]).to eq(previous["sequence"])
      previous.dig("continuation", "service").each do |key, service|
        expect(plan.practice_schedule.dig("continuation", "service", "ruby_rails", key)).to eq(
          "last_lane" => nil, "last_maintenance" => nil, "concepts" => service.fetch("concepts"))
      end
    else
      expect(plan.practice_schedule["sequence"]).to eq(previous.fetch("sequence") + 1)
      expect(plan.practice_schedule.dig("continuation", "kind_service", "ruby_rails", replacement)).to eq(plan.practice_schedule["sequence"])
    end
    plan
  end

  [ false, true ].each do |replacing|
    it "withholds a pending trap and its due check when #{replacing ? 'replacement keeps' : 'variety adds'} the bug hunt" do
      plan = weekend_plan(replacing: replacing)

      expect(plan.code_review_gotcha).to eq(trap)
      expect(plan.notes["bug_hunt"]).to eq(trap.id)
      expect(plan.assignments).to eq({})
      expect(plan.due_checks + plan.fourth_due_checks).to be_empty
      expect(plan.waiting_checks).to include(a_hash_including(concept: trap.concept, reason: :no_host))
      expect(plan.practice_schedule.dig("continuation", "service", "ruby_rails")).to eq(
        "pattern" => { "last_lane" => nil, "last_maintenance" => nil,
          "concepts" => note.dig("continuation", "service", "pattern", "concepts") })
    end
  end

  context "when the chosen set omits the configured bug hunt" do
    let(:pair) { %w[design_comparison code_review] }
    let(:replacement) { "pattern" }

    [ false, true ].each do |replacing|
      it "allows the retry without a trap when #{replacing ? 'replacing the held variety set' : 'selecting variety'}" do
        plan = weekend_plan(replacing: replacing)

        expect(plan.code_review_gotcha).to be_nil
        expect(plan.notes).not_to have_key("bug_hunt")
        expect(plan.assignments.fetch("pattern")).to include(concept: trap.concept, mode: "normal_retry")
      end
    end

    context "with a drill rather than a pending request" do
      let(:requests) { {} }

      it "reloads candidates under the final restrictions instead of refiltering the old excluded list" do
        mastery.update!(next_retention_check_on: nil, drilled_at: Time.current)
        plan = weekend_plan

        expect(plan.code_review_gotcha).to be_nil
        expect(plan.assignments.values).to include(a_hash_including(concept: trap.concept, reason: "drill"))
        expect(mastery.reload.drilled_at).to be_present
      end
    end
  end
end

RSpec.describe DailyPlan, "reinforcement no section can host" do
  include DailyPlanSelectionStubs
  let(:user) { User.create!(email: "plan-unhosted@example.com") }

  before { pin_kind("code_review") }

  def struggled_with(concept)
    exercise = DailyExercise.create!(user: user, date: Date.current - 1, generated_at: Time.current, language: "ruby_rails",
                                     problem_set: { "code_review" => { "concept" => concept } })
    DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current - 1, submitted_at: Time.current,
                          answers: { "code_review" => "x" * 20 }, section_ratings: { "code_review" => "too_hard" },
                          concept_tags: { "code_review" => concept }, ai_review: { "code_review" => { "rating" => "developing" } })
  end

  it "skips a meta-skill concept when the selected schema review cannot tag it" do
    pin_code_review_mode(:schema_review)
    struggled_with("reading_for_intent")

    expect(described_class.for(user, language: "ruby_rails").reinforcement.map { |entry| entry[:concept] })
      .not_to include("reading_for_intent")
  end

  it "keeps it on a day whose code review can tag it" do
    pin_code_review_mode(:application_code)
    struggled_with("reading_for_intent")

    expect(described_class.for(user, language: "ruby_rails").reinforcement.map { |entry| entry[:concept] })
      .to include("reading_for_intent")
  end
end

RSpec.describe DailyPlan, "a pair whose only regular section is architecture" do
  include DailyPlanSelectionStubs
  let(:user) do
    User.create!(email: "plan-architecture-pair@example.com", daily_section_kinds: %w[architecture plan_review])
  end

  before do
    pin_code_review_mode(:application_code)
    pin_kind("code_review")
  end

  def struggled_with(concept, bucket)
    exercise = DailyExercise.create!(user: user, date: Date.current - 1, generated_at: Time.current, language: "ruby_rails",
                                     problem_set: { "code_review" => { "concept" => concept } })
    DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current - 1, submitted_at: Time.current,
                          answers: { "code_review" => "x" * 20 }, section_ratings: { "code_review" => "too_hard" },
                          concept_tags: { "code_review" => concept }, ai_review: { "code_review" => { "rating" => "developing" } })
    user.concept_masteries.create!(concept: concept, language: bucket, tier: :reduced)
  end

  it "reads only the buckets its planned sections can host" do
    expect(DailyPlan.send(:hostable_buckets, "ruby_rails", kinds: [ ExerciseSection::Architecture, ExerciseSection::PlanReview ]))
      .to eq(%w[architecture])
    expect(DailyPlan.send(:hostable_buckets, "ruby_rails", kinds: DailyKinds::DEFAULT + [ ExerciseSection::Architecture ]))
      .to eq(%w[ruby_rails architecture])
  end

  it "never gives the selected architecture section a language concept it cannot host" do
    pin_kind("architecture")
    struggled_with("n_plus_one", "ruby_rails")

    plan = described_class.for(user, language: "ruby_rails")

    expect(plan.kinds).to eq([ ExerciseSection::Architecture ])
    expect(plan.reinforcement.map { |entry| entry[:bucket] }).not_to include("ruby_rails")
  end

  it "never gives a security review a language-bucket concept outside its vocabulary" do
    pin_kind("security_review")
    user.update!(daily_section_kinds: %w[security_review plan_review])
    struggled_with("n_plus_one", "ruby_rails")

    plan = described_class.for(user, language: "ruby_rails")

    expect(plan.kinds).to eq([ ExerciseSection::SecurityReview ])
    expect(plan.reinforcement.map { |entry| entry[:concept] }).not_to include("n_plus_one")
  end
end
