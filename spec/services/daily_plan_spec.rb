require "rails_helper"

module DailyPlanGateStubs
  def stub_gate(count, reason = :held)
    allow(CompetencyGate).to receive(:for).and_return(CompetencyGate::Plan.new(count: count, reason: reason, evidence: {}))
  end

  def open_gate = stub_gate(ExerciseSection::MAX_SECTIONS)
end

RSpec.describe DailyPlan do
  # rails_helper includes AuthHelpers by spec type, and spec/services has no inferred type.
  include AuthHelpers
  include DailyPlanGateStubs

  describe "FOURTH_BUCKET_FOR" do
    it "gives every fourth-slot kind its own bucket" do
      expect(DailyPlan::FOURTH_BUCKET_FOR.keys.map(&:to_s))
        .to match_array(ExerciseSection.fourths.map(&:key))
      expect(DailyPlan::FOURTH_BUCKET_FOR[:pseudocode_to_code]).to eq(ConceptBucket::PSEUDOCODE_TO_CODE)
      expect(DailyPlan::FOURTH_BUCKET_FOR.values).to all(be_present)
      expect(DailyPlan::FOURTH_BUCKET_FOR.values.uniq.size).to eq(DailyPlan::FOURTH_BUCKET_FOR.size)
    end
  end
  let(:user) { User.create!(email: "prompt@example.com", name: "Prompt") }

  def due_slice
    user.concepts_due_for_retention_check_in(ConceptBucket.slice_for("mixed"))
  end

  def day_hosts
    DayHosts.new("ruby_rails", mode: :application_code)
  end

  describe "retention check selection" do
    it "releases the fourth slot after a skipped due check and leaves a not-yet-due repeat unchanged" do
      user.update!(daily_section_count: ExerciseSection::MAX_SECTIONS)
      allow(SectionRotation).to receive(:for).and_return(pattern: :pattern, third: :challenge, fourth: :plan_review)
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
          ConceptMastery.record_review!(response, sections: %w[plan_review], apply_session_countdown: false)
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

      result = DailyPlan.send(:established_concepts_for, user, "ruby_rails", kinds: [ ExerciseSection::Architecture ],
                              reinforcement: [], due_checks: [])
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
      expect(DailyPlan.send(:overdue_retention_check_pending_for_bucket?, user, "plan_review")).to be(false)

      user.concept_masteries.find_by(concept: "scope_creep").update!(next_retention_check_on: Date.current - 10)
      expect(DailyPlan.send(:overdue_retention_check_pending_for_bucket?, user, "plan_review")).to be(true)
    end
  end

  describe "#for with the fourth slot" do
    it "carries the fourth kind and its own reinforcement, due_checks, and established when one is chosen" do
      allow(SectionRotation).to receive(:for).and_return(pattern: nil, third: :challenge, fourth: :plan_review)
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
      allow(SectionRotation).to receive(:for).and_return(pattern: :pattern, third: :challenge, fourth: :plan_review)

      result = DailyPlan.for(user, language: "ruby_rails")
      expect(result.reinforcement.map { |h| h[:concept] }).not_to include("scope_creep")
      expect(result.fourth_reinforcement.map { |h| h[:concept] }).to include("scope_creep")
    end

    it "reserves the fourth slot's single slot for retention only once meaningfully overdue" do
      user.concept_masteries.create!(concept: "scope_creep", language: "plan_review", tier: :standard,
                                     mastered_at: 1.month.ago, retention_interval_days: 7,
                                     next_retention_check_on: Date.current - 1)
      allow(user).to receive(:concepts_needing_reinforcement).and_call_original
      allow(user).to receive(:concepts_needing_reinforcement).with(bucket: "plan_review")
        .and_return([ { concept: "unjustified_constant", bucket: "plan_review", tier: "standard" } ])
      allow(SectionRotation).to receive(:for).and_return(pattern: :pattern, third: :challenge, fourth: :plan_review)

      result = DailyPlan.for(user, language: "ruby_rails")
      expect(result.fourth_due_checks).to eq([])

      user.concept_masteries.find_by(concept: "scope_creep").update!(next_retention_check_on: Date.current - 10)
      result = DailyPlan.for(user, language: "ruby_rails")
      expect(result.fourth_due_checks.map(&:concept)).to eq(%w[scope_creep])
    end

    it "caps fourth-slot reinforcement at the slot's single capacity" do
      allow(user).to receive(:concepts_needing_reinforcement).and_call_original
      allow(user).to receive(:concepts_needing_reinforcement).with(bucket: "plan_review")
        .and_return([ { concept: "scope_creep", bucket: "plan_review", tier: "standard" },
                      { concept: "unjustified_constant", bucket: "plan_review", tier: "standard" },
                      { concept: "unflagged_behavior_change", bucket: "plan_review", tier: "standard" } ])
      allow(SectionRotation).to receive(:for).and_return(pattern: :pattern, third: :challenge, fourth: :plan_review)

      result = DailyPlan.for(user, language: "ruby_rails")

      expect(result.fourth_reinforcement.size).to eq(DailyPlan::FOURTH_SLOT_CAPACITY)
      expect(result.fourth_reinforcement.map { |h| h[:concept] }).to eq(%w[scope_creep])
    end

    it "drops fourth-slot reinforcement entirely when an overdue retention check takes the slot" do
      user.concept_masteries.create!(concept: "scope_creep", language: "plan_review", tier: :standard,
                                     mastered_at: 1.month.ago, retention_interval_days: 7,
                                     next_retention_check_on: Date.current - 10)
      allow(user).to receive(:concepts_needing_reinforcement).and_call_original
      allow(user).to receive(:concepts_needing_reinforcement).with(bucket: "plan_review")
        .and_return([ { concept: "unjustified_constant", bucket: "plan_review", tier: "standard" } ])
      allow(SectionRotation).to receive(:for).and_return(pattern: :pattern, third: :challenge, fourth: :plan_review)

      result = DailyPlan.for(user, language: "ruby_rails")

      expect(result.fourth_due_checks.map(&:concept)).to eq(%w[scope_creep])
      expect(result.fourth_reinforcement).to eq([])
    end
  end

  describe "CODE_REVIEW_MODE_WEIGHTS" do
    it "splits three ways, summing to 1.0" do
      expect(DailyPlan::CODE_REVIEW_MODE_WEIGHTS.keys)
        .to eq(%i[application_code test_file schema_review])
      expect(DailyPlan::CODE_REVIEW_MODE_WEIGHTS.values.sum).to be_within(0.001).of(1.0)
    end

    it "reaches every mode" do
      { 0.0 => :application_code, 0.34 => :test_file, 0.67 => :schema_review }.each do |value, expected|
        allow(WeightedRoll).to receive(:rand).and_return(value)
        expect(WeightedRoll.pick(DailyPlan::CODE_REVIEW_MODE_WEIGHTS)).to eq(expected)
      end
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
    let(:user) { User.create!(email: "plan@example.com", name: "Plan") }

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

  describe ".for with a variable-length day" do
    let(:user) { User.create!(email: "plan@example.com", name: "Plan") }

    before { allow(SectionCount).to receive(:for).and_return(2) }

    it "carries the chosen slots, leaving the unchosen ones nil" do
      open_gate
      allow(SectionCount).to receive(:for).and_return(3)
      plan = described_class.for(user, language: "ruby_rails")

      chosen = [ plan.pattern, plan.third, plan.fourth ].compact

      expect(chosen.size).to eq(1)
    end

    it "skips the fourth track entirely when no fourth section was chosen" do
      allow(SectionRotation).to receive(:for).and_return(pattern: nil, third: :challenge, fourth: nil)

      plan = described_class.for(user, language: "ruby_rails")

      expect(plan.fourth).to be_nil
      expect(plan.fourth_reinforcement).to eq([])
      expect(plan.fourth_due_checks).to eq([])
      expect(plan.fourth_established).to eq([])
    end

    it "sizes the reinforcement pool to the slots that can host a language concept" do
      allow(user).to receive(:concepts_needing_reinforcement).and_return([])
      %w[n_plus_one transaction_safety memoization].each_with_index do |concept, i|
        user.concept_masteries.create!(concept: concept, language: "ruby_rails", tier: :standard,
                                       mastered_at: 1.month.ago, retention_interval_days: 7,
                                       next_retention_check_on: Date.current - (i + 1))
      end

      allow(SectionRotation).to receive(:for).and_return(pattern: nil, third: nil, fourth: :plan_review)
      code_review_and_fourth_only = described_class.for(user, language: "ruby_rails")

      allow(SectionRotation).to receive(:for).and_return(pattern: nil, third: :challenge, fourth: nil)
      code_review_and_third = described_class.for(user, language: "ruby_rails")

      expect(code_review_and_fourth_only.due_checks.size).to eq(2)
      expect(code_review_and_third.due_checks.size).to eq(3)
    end

    it "truncates the reinforcement list itself to what the day can host" do
      allow(user).to receive(:concepts_needing_reinforcement).with(exclude_buckets: anything, hostable: anything).and_return(
        [ { concept: "n_plus_one", bucket: "ruby_rails", tier: "standard" }, { concept: "memoization", bucket: "ruby_rails", tier: "standard" },
          { concept: "idempotency", bucket: "ruby_rails", tier: "standard" } ]
      )
      allow(user).to receive(:concepts_needing_reinforcement).with(bucket: anything).and_return([])
      allow(SectionRotation).to receive(:for).and_return(pattern: nil, third: nil, fourth: nil)

      plan = described_class.for(user, language: "ruby_rails")

      expect(plan.reinforcement.map { |h| h[:concept] }).to eq(%w[n_plus_one memoization])
    end

    # On a schema-review day no fixed section could tag a core Ruby concept, and the check would wait.
    it "gives a reinforcement entry up when an overdue check takes the slot back" do
      pin_code_review_mode(:application_code)
      allow(user).to receive(:concepts_needing_reinforcement).with(exclude_buckets: anything, hostable: anything).and_return(
        [ { concept: "n_plus_one", bucket: "ruby_rails", tier: "standard" }, { concept: "memoization", bucket: "ruby_rails", tier: "standard" } ]
      )
      allow(user).to receive(:concepts_needing_reinforcement).with(bucket: anything).and_return([])
      user.concept_masteries.create!(concept: "transaction_safety", language: "ruby_rails", tier: :standard,
                                     mastered_at: 6.months.ago, retention_interval_days: 7,
                                     next_retention_check_on: 6.months.ago.to_date)
      allow(SectionRotation).to receive(:for).and_return(pattern: nil, third: nil, fourth: nil)

      plan = described_class.for(user, language: "ruby_rails")

      expect(plan.reinforcement.map { |h| h[:concept] }).to eq(%w[n_plus_one])
      expect(plan.due_checks.map(&:concept)).to eq(%w[transaction_safety])
    end
  end

  describe "the Daily sections setting" do
    it "passes a fixed choice through to DaySize, which overrides completion and the gate" do
      user = User.create!(email: "fixed@example.com", name: "Fixed", daily_section_count: 3)
      allow(SectionCount).to receive(:for).and_return(ExerciseSection::MAX_SECTIONS)
      stub_gate(SectionCount::FLOOR, :brake)
      expect(DaySize).to receive(:for).with(hash_including(setting: 3)).and_call_original

      plan = described_class.for(user, language: "ruby_rails")

      expect([ plan.pattern, plan.third, plan.fourth ].compact.size).to eq(3 - ExerciseSection.fixed.size)
      expect(plan.size.reason).to eq(:setting)
    end

    it "gives a user who chose the largest day every slot" do
      user = User.create!(email: "full@example.com", name: "Full", daily_section_count: ExerciseSection::MAX_SECTIONS)

      plan = described_class.for(user, language: "ruby_rails")

      optional_slots = ExerciseSection::MAX_SECTIONS - ExerciseSection.fixed.size
      expect([ plan.pattern, plan.third, plan.fourth ].compact.size).to eq(optional_slots)
    end

    it "leaves sizing Automatic for a user who never chose" do
      user = User.create!(email: "auto@example.com", name: "Auto")
      expect(DaySize).to receive(:for).with(hash_including(setting: nil)).and_call_original

      expect(described_class.for(user, language: "ruby_rails").size.automatic?).to be(true)
    end
  end

  describe "the day's size" do
    let(:user) { User.create!(email: "size@example.com", name: "Size") }

    def optional_kinds(plan) = [ plan.pattern, plan.third, plan.fourth ].compact

    it "starts a new account at the floor, from the gate's own evidence" do
      plan = described_class.for(user, language: "ruby_rails")

      expect(plan.size.count).to eq(SectionCount::FLOOR)
      expect(plan.size.reason).to eq(:gate)
      expect(plan.size.gate.evidence[:to_three]).to include(required: CompetencyGate::GROW_TO_THREE.of, available: 0)
      expect(optional_kinds(plan)).to eq([])
    end

    it "takes the gate when it is lower than completion" do
      allow(SectionCount).to receive(:for).and_return(4)
      stub_gate(3, :grew)

      plan = described_class.for(user, language: "ruby_rails")

      expect(plan.size.count).to eq(3)
      expect(optional_kinds(plan).size).to eq(3 - ExerciseSection.fixed.size)
    end

    it "takes completion when it is lower than the gate" do
      allow(SectionCount).to receive(:for).and_return(3)
      open_gate

      expect(optional_kinds(described_class.for(user, language: "ruby_rails")).size).to eq(3 - ExerciseSection.fixed.size)
    end

    it "lets a fixed setting override the gate and the brake" do
      user.update!(daily_section_count: ExerciseSection::MAX_SECTIONS)
      stub_gate(SectionCount::FLOOR, :brake)

      plan = described_class.for(user, language: "ruby_rails")

      expect(optional_kinds(plan).size).to eq(ExerciseSection::MAX_SECTIONS - ExerciseSection.fixed.size)
      expect(plan.size.brake?).to be(false)
    end

    it "runs the gate once per plan" do
      expect(CompetencyGate).to receive(:for).once.and_call_original

      described_class.for(user, language: "ruby_rails")
    end

    it "records the planned size and its reason in the notes" do
      allow(SectionCount).to receive(:for).and_return(4)
      stub_gate(3, :grew)

      expect(described_class.for(user, language: "ruby_rails").notes).to include("size" => 3, "size_reason" => "gate")
    end
  end

  describe "#code_review_mode on the plan" do
    let(:user) { User.create!(email: "plan@example.com", name: "Plan") }

    it "is carried on the Result" do
      allow(WeightedRoll).to receive(:rand).and_return(0.67)
      expect(DailyPlan.for(user, language: "ruby_rails").code_review_mode).to eq(:schema_review)
    end
  end

  describe "#code_review_source on the plan" do
    let(:user) { User.create!(email: "source@example.com", name: "Source") }

    def plan(language: "ruby_rails", mode: :application_code, roll: :real)
      allow(WeightedRoll).to receive(:pick).with(DailyPlan::CODE_REVIEW_MODE_WEIGHTS).and_return(mode)
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
      allow(WeightedRoll).to receive(:pick).with(DailyPlan::CODE_REVIEW_MODE_WEIGHTS).and_return(:test_file)

      DailyPlan.for(user, language: "ruby_rails")
    end

    it "prefers what this user has not seen, reading the stamped trace" do
      first = RealSource::APPLICATION_CODE.first
      user.daily_exercises.create!(date: Date.current - 1, generated_at: Time.current, language: "ruby_rails",
                                   problem_set: { "code_review" => { "source" => first.id } })

      expect(plan.code_review_source).to eq(RealSource::APPLICATION_CODE.second)
    end
  end

  describe "stated rotation preferences" do
    it "hands the user's stated preferences to the rotation" do
      user = create_fake_provider_user
      user.update!(excluded_section_kinds: [ "parsons_problem" ])

      allow(SectionRotation).to receive(:for).and_call_original

      described_class.for(user, language: "ruby_rails")

      expect(SectionRotation).to have_received(:for) do |_history, count:, preferences:|
        expect(count).to be_a(Integer)
        expect(preferences.excluded?(ExerciseSection::ParsonsProblem)).to be(true)
      end
    end
  end

  describe "difficulty targets" do
    it "never reads KindDifficulty and plans the same day regardless" do
      allow(SectionRotation).to receive(:for).and_return(pattern: :pattern, third: :challenge, fourth: :plan_review)
      pin_code_review_mode(:application_code)
      allow(WeightedRoll).to receive(:pick).with(DailyPlan::SCENARIO_FLAVOR_WEIGHTS).and_return(:general)
      expect(KindDifficulty).not_to receive(:for)
      expect(KindDifficulty).not_to receive(:new)

      untargeted = DailyPlan.for(user, language: "ruby_rails")
      user.update!(section_kind_levels: { "code_review" => "senior", "challenge" => "junior" })
      targeted = DailyPlan.for(user.reload, language: "ruby_rails")
      user.update!(locked_section_kinds: [ "code_review", "challenge" ])
      locked = DailyPlan.for(user.reload, language: "ruby_rails")

      expect(targeted).to eq(untargeted)
      expect(locked).to eq(untargeted)
    end
  end
end

RSpec.describe DailyPlan, "drilled concepts" do
  let(:user) { User.create!(email: "plan-drill@example.com", name: "Plan") }

  def submit(concept, section: "code_review", date:)
    exercise = DailyExercise.create!(user: user, date: date, generated_at: Time.current, language: "ruby_rails",
                                     problem_set: { section => { "concept" => concept } })
    DailyResponse.create!(user: user, daily_exercise: exercise, date: date, submitted_at: Time.current,
                          answers: { section => "x" * 20 }, section_ratings: { section => "too_hard" },
                          concept_tags: { section => concept }, ai_review: { section => { "rating" => "developing" } })
  end

  it "keeps drilled concepts when truncating reinforcement to today's hosts" do
    submit("n_plus_one", date: Date.current - 1)
    submit("transaction_safety", date: Date.current - 2)
    ConceptDrills.start!(user, concept: "memoization", bucket: "ruby_rails")
    allow(SectionRotation).to receive(:for).and_return(pattern: nil, third: nil, fourth: nil)

    plan = described_class.for(user, language: "ruby_rails")

    expect(plan.reinforcement).to eq([
      { concept: "memoization", bucket: "ruby_rails", tier: "standard", drilled: true },
      { concept: "n_plus_one", bucket: "ruby_rails", tier: "standard" }
    ])
  end

  it "offers a drilled architecture concept only on a day with an architecture section" do
    ConceptDrills.start!(user, concept: "sync_vs_async", bucket: "architecture")

    allow(SectionRotation).to receive(:for).and_return(pattern: :pattern, third: :challenge, fourth: nil)
    expect(described_class.for(user, language: "ruby_rails").reinforcement).to eq([])

    allow(SectionRotation).to receive(:for).and_return(pattern: :pattern, third: :architecture, fourth: nil)
    expect(described_class.for(user, language: "ruby_rails").reinforcement.map { |h| h[:concept] }).to eq(%w[sync_vs_async])
  end

  it "offers a drilled data-modeling concept only when a section today can tag it" do
    ConceptDrills.start!(user, concept: "denormalization_tradeoffs", bucket: "ruby_rails")
    allow(SectionRotation).to receive(:for).and_return(pattern: nil, third: nil, fourth: :plan_review)

    pin_code_review_mode(:application_code)
    expect(described_class.for(user, language: "ruby_rails").reinforcement).to eq([])

    pin_code_review_mode(:schema_review)
    expect(described_class.for(user, language: "ruby_rails").reinforcement.map { |h| h[:concept] })
      .to eq(%w[denormalization_tradeoffs])
  end

  it "leaves one host for evidence-driven reinforcement when a group drill could fill the day" do
    submit("n_plus_one", date: Date.current - 1)
    ConceptDrills.start_group!(user, group: "data_modeling", bucket: "ruby_rails")
    allow(SectionRotation).to receive(:for).and_return(pattern: :pattern, third: :challenge, fourth: nil)

    plan = described_class.for(user, language: "ruby_rails")

    expect(plan.reinforcement.size).to eq(4)
    expect(plan.reinforcement.count { |h| h[:drilled] }).to eq(3)
    expect(plan.reinforcement.last).to eq(concept: "n_plus_one", bucket: "ruby_rails", tier: "standard")
  end

  it "shares the two fixed hosts between a drill and the evidence waiting" do
    submit("n_plus_one", date: Date.current - 1)
    ConceptDrills.start!(user, concept: "memoization", bucket: "ruby_rails")
    allow(SectionRotation).to receive(:for).and_return(pattern: nil, third: nil, fourth: nil)
    pin_code_review_mode(:application_code)

    plan = described_class.for(user, language: "ruby_rails")

    expect(plan.reinforcement.map { |h| h[:concept] }).to eq(%w[memoization n_plus_one])
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
    allow(SectionRotation).to receive(:for).and_return(pattern: nil, third: nil, fourth: nil)
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
    allow(SectionRotation).to receive(:for).and_return(pattern: :pattern, third: :challenge, fourth: nil)

    plan = described_class.for(user, language: "ruby_rails")

    expect(plan.reinforcement.map { |h| h[:concept] }).to eq(%w[memoization])
    expect(plan.due_checks).to eq([])
  end

  it "gives a drilled fourth-bucket concept the fourth slot" do
    submit("scope_creep", section: "plan_review", date: Date.current - 1)
    ConceptDrills.start!(user, concept: "unjustified_constant", bucket: "plan_review")
    allow(SectionRotation).to receive(:for).and_return(pattern: :pattern, third: :challenge, fourth: :plan_review)

    plan = described_class.for(user, language: "ruby_rails")

    expect(plan.fourth_reinforcement).to eq([ { concept: "unjustified_constant", bucket: "plan_review", tier: "standard", drilled: true } ])
    expect(plan.reinforcement).to eq([])
  end

  it "keeps a drilled fourth concept out of the fourth retention checks" do
    ConceptDrills.start!(user, concept: "unjustified_constant", bucket: "plan_review")
    user.concept_masteries.find_by(concept: "unjustified_constant").update!(
      mastered_at: 1.month.ago, retention_interval_days: 7, next_retention_check_on: Date.current - 20
    )
    allow(SectionRotation).to receive(:for).and_return(pattern: :pattern, third: :challenge, fourth: :plan_review)

    plan = described_class.for(user, language: "ruby_rails")

    expect(plan.fourth_reinforcement.map { |h| h[:concept] }).to eq(%w[unjustified_constant])
    expect(plan.fourth_due_checks).to eq([])
  end
end

RSpec.describe DailyPlan, "same-named concepts across language buckets" do
  let(:user) { User.create!(email: "plan-mixed@example.com", name: "Plan", language: "mixed") }

  it "lets a ruby retention check stand when only the javascript occurrence is in reinforcement" do
    exercise = user.daily_exercises.create!(date: Date.current - 1, generated_at: Time.current, language: "javascript",
      problem_set: { "code_review" => { "concept" => "over_mocking" } })
    user.daily_responses.create!(daily_exercise: exercise, date: exercise.date, submitted_at: Time.current,
      answers: { "code_review" => "x" * 20 }, section_ratings: { "code_review" => "too_hard" },
      concept_tags: { "code_review" => "over_mocking" }, ai_review: { "code_review" => { "rating" => "developing" } })
    user.concept_masteries.create!(concept: "over_mocking", language: "ruby_rails", tier: :standard,
                                   mastered_at: 1.month.ago, retention_interval_days: 7, next_retention_check_on: Date.current - 20)
    allow(SectionRotation).to receive(:for).and_return(pattern: :pattern, third: :challenge, fourth: nil)

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
    defaults = DailyPlan::Result.members.index_with { nil }
    DailyPlan::Result.new(**defaults, **overrides)
  end

  it "records only what applied" do
    expect(result.notes).to eq({})
    expect(result(shared_concept: "feature_envy").notes).to eq("shared_concept" => "feature_envy")
    gap = CoverageException::Addition.new(kind: ExerciseSection::Pattern, reason: :gap)
    expect(result(coverage: gap).notes).to eq("coverage" => "pattern", "coverage_reason" => "gap")
  end

  it "records the planned size beside a coverage addition" do
    size = DaySize.for(setting: nil, completion: 2, gate: CompetencyGate::Plan.new(count: 2, reason: :held, evidence: {}))
    gap = CoverageException::Addition.new(kind: ExerciseSection::Pattern, reason: :gap)

    expect(result(size: size, coverage: gap).notes)
      .to eq("size" => 2, "size_reason" => "completion", "coverage" => "pattern", "coverage_reason" => "gap")
  end
end

RSpec.describe DailyPlan, "the shared concept" do
  let(:user) { User.create!(email: "plan-shared@example.com", name: "Plan") }

  before do
    pin_code_review_mode(:application_code)
    allow(SectionRotation).to receive(:for).and_return(pattern: :pattern, third: nil, fourth: nil)
  end

  def struggled_with(concept, tier:, date: Date.current - 1)
    exercise = DailyExercise.create!(user: user, date: date, generated_at: Time.current, language: "ruby_rails",
                                     problem_set: { "code_review" => { "concept" => concept } })
    DailyResponse.create!(user: user, daily_exercise: exercise, date: date, submitted_at: Time.current,
                          answers: { "code_review" => "x" * 20 }, section_ratings: { "code_review" => "too_hard" },
                          concept_tags: { "code_review" => concept }, ai_review: { "code_review" => { "rating" => "developing" } })
    user.concept_masteries.create!(concept: concept, language: "ruby_rails", tier: tier)
  end

  it "places a reduced-tier concept both fixed sections can tag in both of them" do
    struggled_with("n_plus_one", tier: :reduced)

    plan = described_class.for(user, language: "ruby_rails")

    expect(plan.shared_concept).to eq("n_plus_one")
    expect(plan.notes).to eq("size" => SectionCount::FLOOR, "size_reason" => "gate", "shared_concept" => "n_plus_one")
  end

  it "never shares a paused concept" do
    struggled_with("n_plus_one", tier: :paused)

    expect(described_class.for(user, language: "ruby_rails").shared_concept).to be_nil
  end

  it "does not share a standard-tier concept" do
    struggled_with("n_plus_one", tier: :standard)

    expect(described_class.for(user, language: "ruby_rails").shared_concept).to be_nil
  end

  it "falls back to no share when one fixed section cannot tag the concept" do
    struggled_with("transaction_safety", tier: :reduced)

    plan = described_class.for(user, language: "ruby_rails")

    expect(plan.shared_concept).to be_nil
    expect(plan.reinforcement.map { |h| h[:concept] }).to eq(%w[transaction_safety])
  end

  it "skips past an ineligible reduced concept to the first one both can tag" do
    struggled_with("transaction_safety", tier: :reduced, date: Date.current - 1)
    struggled_with("memoization", tier: :reduced, date: Date.current - 2)

    expect(described_class.for(user, language: "ruby_rails").shared_concept).to eq("memoization")
  end

  it "pairs into a host nothing else wanted and leaves reinforcement as it was" do
    struggled_with("n_plus_one", tier: :reduced, date: Date.current - 1)
    struggled_with("memoization", tier: :standard, date: Date.current - 2)

    plan = described_class.for(user, language: "ruby_rails")

    expect(plan.shared_concept).to eq("n_plus_one")
    expect(plan.reinforcement.map { |h| h[:concept] }).to eq(%w[n_plus_one memoization])
  end

  it "does not pair when reinforcement already fills every host" do
    struggled_with("n_plus_one", tier: :reduced, date: Date.current - 1)
    struggled_with("memoization", tier: :standard, date: Date.current - 2)
    struggled_with("service_objects", tier: :standard, date: Date.current - 3)

    plan = described_class.for(user, language: "ruby_rails")

    expect(plan.shared_concept).to be_nil
    expect(plan.reinforcement.map { |h| h[:concept] }).to eq(%w[n_plus_one memoization service_objects])
  end

  it "keeps a drill rather than evicting it for the pairing on a two-section day" do
    allow(SectionRotation).to receive(:for).and_return(pattern: nil, third: nil, fourth: nil)
    struggled_with("n_plus_one", tier: :reduced)
    ConceptDrills.start!(user, concept: "memoization", bucket: "ruby_rails")

    plan = described_class.for(user, language: "ruby_rails")

    expect(plan.shared_concept).to be_nil
    expect(plan.reinforcement.map { |h| h[:concept] }).to eq(%w[memoization n_plus_one])
  end

  it "plans exactly the unpaired day when an overdue retention check takes the free host" do
    allow(SectionRotation).to receive(:for).and_return(pattern: nil, third: nil, fourth: nil)
    allow(WeightedRoll).to receive(:pick).with(DailyPlan::SCENARIO_FLAVOR_WEIGHTS).and_return(:general)
    struggled_with("n_plus_one", tier: :reduced)
    user.concept_masteries.create!(concept: "memoization", language: "ruby_rails", tier: :standard,
                                   mastered_at: 6.months.ago, retention_interval_days: 7,
                                   next_retention_check_on: 6.months.ago.to_date)

    paired = described_class.for(user, language: "ruby_rails")
    allow(SharedConcept).to receive(:pick).and_return(nil)
    unpaired = described_class.for(user, language: "ruby_rails")

    expect(paired).to eq(unpaired)
    expect(paired.due_checks.map(&:concept)).to eq(%w[memoization])
  end

  it "reads the schema-review vocabulary on a schema-review day" do
    pin_code_review_mode(:schema_review)
    struggled_with("n_plus_one", tier: :reduced)

    expect(described_class.for(user, language: "ruby_rails").shared_concept).to be_nil
  end
end

RSpec.describe DailyPlan, "retention checks left waiting" do
  include DailyPlanGateStubs

  let(:user) { User.create!(email: "plan-waiting@example.com", name: "Plan") }

  # Otherwise the coverage exception would read the stubbed day as floored with a check to host.
  before do
    open_gate
    pin_code_review_mode(:application_code)
    allow(SectionRotation).to receive(:for).and_return(pattern: :pattern, third: :challenge, fourth: nil)
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

  it "says no_slot when a section could tag the check but reinforcement took every host" do
    allow(user).to receive(:concepts_needing_reinforcement).with(exclude_buckets: anything, hostable: anything).and_return(
      %w[n_plus_one service_objects query_objects policy_objects].map { |c| { concept: c, bucket: "ruby_rails", tier: "standard" } }
    )
    due("memoization", "ruby_rails")

    expect(waiting).to eq([ { bucket: "ruby_rails", concept: "memoization", reason: :no_slot } ])
  end

  it "leaves out a check the day offers and one reinforcement already carries" do
    allow(user).to receive(:concepts_needing_reinforcement).with(exclude_buckets: anything, hostable: anything)
      .and_return([ { concept: "n_plus_one", bucket: "ruby_rails", tier: "standard" } ])
    due("memoization", "ruby_rails")
    due("n_plus_one", "ruby_rails")

    plan = described_class.for(user, language: "ruby_rails")

    expect(plan.due_checks.map(&:concept)).to eq(%w[memoization])
    expect(plan.waiting_checks).to eq([])
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

RSpec.describe DailyPlan, "the coverage exception" do
  include ActiveSupport::Testing::TimeHelpers
  include DailyPlanGateStubs

  let(:user) { User.create!(email: "plan-coverage@example.com", name: "Plan") }

  around { |example| travel_to(Time.zone.local(2026, 10, 7, 9)) { example.run } }

  before do
    pin_code_review_mode(:application_code)
    allow(SectionCount).to receive(:for).and_return(ExerciseSection.fixed.size)
  end

  def two_section_day(date, plan_notes: {})
    user.daily_exercises.create!(date: date, generated_at: Time.current, language: "ruby_rails", plan_notes: plan_notes,
                                 problem_set: { "code_review" => { "concept" => "n_plus_one" },
                                                "design_comparison" => { "concept" => "open_closed" } })
  end

  def overdue_architecture_check
    user.concept_masteries.create!(concept: "service_boundaries", language: "architecture", tier: :standard,
                                   mastered_at: 6.months.ago, retention_interval_days: 7,
                                   next_retention_check_on: Date.current - 30)
  end

  it "adds the kind that can host an overdue waiting check, and the check lands there" do
    overdue_architecture_check

    plan = described_class.for(user, language: "ruby_rails")

    expect(plan.coverage.kind).to eq(ExerciseSection::Architecture)
    expect(plan.coverage.reason).to eq(:due_check)
    expect(plan.coverage.check).to include(concept: "service_boundaries", bucket: "architecture")
    expect(plan.third).to eq(:architecture)
    expect(plan.due_checks.map(&:concept)).to eq(%w[service_boundaries])
    expect(plan.waiting_checks).to eq([])
    expect(plan.notes).to eq("size" => SectionCount::FLOOR, "size_reason" => "completion",
                             "coverage" => "architecture", "coverage_reason" => "due_check")
  end

  it "gives the addition up when the check it was added for does not land" do
    allow(user).to receive(:concepts_needing_reinforcement).with(exclude_buckets: anything, hostable: anything).and_return(
      %w[service_objects query_objects policy_objects].map { |c| { concept: c, bucket: "ruby_rails", tier: "standard" } }
    )
    user.concept_masteries.create!(concept: "n_plus_one", language: "ruby_rails", tier: :standard, mastered_at: 6.months.ago,
                                   retention_interval_days: 7, next_retention_check_on: Date.current - 40)
    user.concept_masteries.create!(concept: "memoization", language: "ruby_rails", tier: :standard, mastered_at: 6.months.ago,
                                   retention_interval_days: 7, next_retention_check_on: Date.current - 30)

    plan = described_class.for(user, language: "ruby_rails")

    expect(plan.coverage).to be_nil
    expect([ plan.pattern, plan.third, plan.fourth ].compact).to eq([])
    expect(plan.due_checks.map(&:concept)).to eq(%w[n_plus_one])
    expect(plan.waiting_checks.map { |w| w.slice(:concept, :reason) }).to eq([ { concept: "memoization", reason: :no_slot } ])
    expect(plan.notes).not_to have_key("coverage")
  end

  it "adds the longest-unseen kind once the gap has run past four weeks" do
    two_section_day(Date.current - 60)

    plan = described_class.for(user, language: "ruby_rails")

    expect(plan.coverage).to eq(CoverageException::Addition.new(kind: ExerciseSection::Pattern, reason: :gap))
    expect(plan.pattern).to eq(:pattern)
  end

  it "adds nothing while the brake is on, and the check waits with no host" do
    overdue_architecture_check
    stub_gate(SectionCount::FLOOR, :brake)

    plan = described_class.for(user, language: "ruby_rails")

    expect(plan.size.brake?).to be(true)
    expect(plan.coverage).to be_nil
    expect([ plan.pattern, plan.third, plan.fourth ].compact).to eq([])
    expect(plan.waiting_checks.map { |w| w.slice(:concept, :reason) }).to eq([ { concept: "service_boundaries", reason: :no_host } ])
  end

  it "leaves a check no fixed section can tag waiting, and adds a kind that can host it" do
    pin_code_review_mode(:schema_review)
    user.concept_masteries.create!(concept: "transaction_safety", language: "ruby_rails", tier: :standard,
                                   mastered_at: 6.months.ago, retention_interval_days: 7, next_retention_check_on: Date.current - 30)

    plan = described_class.for(user, language: "ruby_rails")

    expect(plan.coverage.reason).to eq(:due_check)
    expect(plan.due_checks.map(&:concept)).to eq(%w[transaction_safety])
    expect(plan.waiting_checks).to eq([])
  end

  it "under a fixed two, leaves that check waiting rather than selecting it for a section that cannot tag it" do
    pin_code_review_mode(:schema_review)
    user.update!(daily_section_count: 2)
    user.concept_masteries.create!(concept: "transaction_safety", language: "ruby_rails", tier: :standard,
                                   mastered_at: 6.months.ago, retention_interval_days: 7, next_retention_check_on: Date.current - 30)

    plan = described_class.for(user, language: "ruby_rails")

    expect(plan.due_checks).to eq([])
    expect(plan.waiting_checks.map { |w| w.slice(:concept, :reason) }).to eq([ { concept: "transaction_safety", reason: :no_host } ])
  end

  it "adds nothing under a fixed two, and the check waits with no host" do
    user.update!(daily_section_count: 2)
    overdue_architecture_check

    plan = described_class.for(user, language: "ruby_rails")

    expect(plan.coverage).to be_nil
    expect([ plan.pattern, plan.third, plan.fourth ].compact).to eq([])
    expect(plan.waiting_checks.map { |w| w.slice(:concept, :reason) }).to eq([ { concept: "service_boundaries", reason: :no_host } ])
  end

  it "adds nothing within four weekdays of the last addition" do
    overdue_architecture_check
    two_section_day(Date.current - 1, plan_notes: { "coverage" => "pattern" })

    expect(described_class.for(user, language: "ruby_rails").coverage).to be_nil
  end

  it "does not load the gaps on a day the cap holds" do
    two_section_day(Date.current - 1, plan_notes: { "coverage" => "pattern" })
    expect(CoverageException::History).not_to receive(:for)

    expect(described_class.for(user, language: "ruby_rails").coverage).to be_nil
  end

  it "does not read the coverage history on a day it cannot apply to" do
    open_gate
    allow(SectionCount).to receive(:for).and_return(ExerciseSection.fixed.size + 1)
    expect(CoverageException::History).not_to receive(:for)
    expect(CoverageException::History).not_to receive(:recent_coverage_dates)

    described_class.for(user, language: "ruby_rails")
  end
end
