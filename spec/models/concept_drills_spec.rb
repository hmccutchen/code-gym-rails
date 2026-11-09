require "rails_helper"

RSpec.describe ConceptDrills do
  let(:user) { User.create!(email: "drills@example.com") }

  def row(concept, bucket = "ruby_rails")
    user.concept_masteries.find_by(concept: concept, language: bucket)
  end

  describe "Start outcomes" do
    it "refuses a valid drill before any write when a persisted schedule has an incompatible kind/bucket identity" do
      selected = PracticeSchedule.plan(context: nil, count: DailyKinds::COUNT, setting: DailyKinds::COUNT, daily: DailyKinds::DEFAULT,
        preferences: KindPreferences.none, evidence: { initial_reviewed_sets: 0, pending: [], struggle: {} },
        hosts: DayHosts.new("ruby_rails", mode: :application_code), rotation_history: [], due: [], drills: [])
      note = selected.notes
      note["assignments"] = { "code_review" => {
        "concept" => "sync_vs_async", "bucket" => "architecture", "reason" => "support", "adjustment" => "support"
      } }
      exercise = user.daily_exercises.create!(date: Date.current, generated_at: Time.current,
        problem_set: selected.kinds.to_h { |kind| [ kind.key, { "question" => "Explain the decision." } ] },
        plan_notes: { "practice_schedule" => note })
      expect(user.concept_masteries.count).to eq(0)

      expect { described_class.start(user, concept: "memoization", bucket: "ruby_rails") }
        .to raise_error(ArgumentError, "Invalid practice schedule format")

      expect(user.concept_masteries.reload).to be_empty
      expect(row("memoization")).to be_nil
      expect(exercise.reload.plan_notes).to eq("practice_schedule" => note)
    end

    it "distinguishes a new single drill from an active repeat without restamping it" do
      expect(described_class.start(user, concept: "n_plus_one", bucket: "ruby_rails").status).to eq(:started)
      stamp = row("n_plus_one").drilled_at
      expect(described_class.start(user, concept: "n_plus_one", bucket: "ruby_rails").status).to eq(:already)
      expect(row("n_plus_one").drilled_at).to eq(stamp)
    end

    it "distinguishes a new group from an active repeat without restamping its members" do
      expect(described_class.start_group(user, group: "module_design", bucket: "ruby_rails").status).to eq(:started)
      stamps = user.concept_masteries.order(:id).pluck(:drilled_at)
      expect(described_class.start_group(user, group: "module_design", bucket: "ruby_rails").status).to eq(:already)
      expect(user.concept_masteries.order(:id).pluck(:drilled_at)).to eq(stamps)
    end

    it "names a reserved single repeat without reactivating it" do
      described_class.start!(user, concept: "n_plus_one", bucket: "ruby_rails")
      partially_review_concept!(user, concept: "n_plus_one")

      expect(described_class.start(user, concept: "n_plus_one", bucket: "ruby_rails").status).to eq(:already_reserved)
      expect(row("n_plus_one").drilled_at).to be_nil
    end

    it "names a reserved group repeat without re-adding its hidden member" do
      described_class.start_group!(user, group: "module_design", bucket: "ruby_rails")
      partially_review_concept!(user, concept: "shallow_module")

      expect(described_class.start_group(user, group: "module_design", bucket: "ruby_rails").status).to eq(:already_reserved)
      expect(row("shallow_module").drilled_at).to be_nil
    end

    [ [ :start, { concept: "transaction_safety" } ], [ :start_group, { group: "module_design" } ] ].each do |command, target|
      it "captures #{command}'s cap refusal and reservation facts before a subsequent Stop" do
        described_class.start!(user, concept: "n_plus_one", bucket: "ruby_rails")
        described_class.start!(user, concept: "memoization", bucket: "ruby_rails")
        partially_review_concept!(user, concept: "n_plus_one")

        outcome = described_class.public_send(command, user, bucket: "ruby_rails", **target)
        described_class.stop!(user, concept: "n_plus_one", bucket: "ruby_rails")

        expect(outcome.status).to eq(:full)
        expect(outcome.drills).to be_full.and be_reservations
        expect(outcome.drills.entries.flat_map(&:concepts)).to contain_exactly("n_plus_one", "memoization")
        expect(described_class.for(user)).not_to be_full
        expect(user.concept_masteries.where.not(concept: %w[n_plus_one memoization])).to be_empty
      end
    end
  end

  describe ".start!" do
    it "creates the row in the never-encountered state for a concept the user has never met" do
      described_class.start!(user, concept: "n_plus_one", bucket: "ruby_rails")

      cm = row("n_plus_one")
      expect(cm.drilled_at).to be_present
      expect(cm.drill_group).to be_nil
      expect(cm.tier).to eq("standard")
      expect(cm.last_rating).to be_nil
      expect(cm.next_retention_check_on).to be_nil
    end

    it "marks an existing row without touching its evidence" do
      user.concept_masteries.create!(concept: "n_plus_one", language: "ruby_rails", tier: :reduced,
                                     streak: 1, last_rating: "developing")

      described_class.start!(user, concept: "n_plus_one", bucket: "ruby_rails")

      cm = row("n_plus_one")
      expect(cm.drilled_at).to be_present
      expect(cm.tier).to eq("reduced")
      expect(cm.streak).to eq(1)
      expect(cm.last_rating).to eq("developing")
    end

    it "ends a pause the way an expired cooldown does" do
      user.concept_masteries.create!(concept: "n_plus_one", language: "ruby_rails", tier: :paused,
                                     streak: 1, cooldown_remaining: 2)

      described_class.start!(user, concept: "n_plus_one", bucket: "ruby_rails")

      cm = row("n_plus_one")
      expect(cm.tier).to eq("reduced")
      expect(cm.streak).to eq(0)
      expect(cm.cooldown_remaining).to eq(0)
    end

    it "refuses a concept outside the bucket's vocabulary" do
      expect { described_class.start!(user, concept: "prototype_chain", bucket: "ruby_rails") }
        .to raise_error(ArgumentError)
    end

    it "refuses a third concurrent drill" do
      described_class.start!(user, concept: "n_plus_one", bucket: "ruby_rails")
      described_class.start!(user, concept: "memoization", bucket: "ruby_rails")

      expect { described_class.start!(user, concept: "transaction_safety", bucket: "ruby_rails") }
        .to raise_error(ConceptDrills::LimitReached)
      expect(row("transaction_safety")).to be_nil
    end

    it "leaves a concept drilled under a group in that group" do
      described_class.start_group!(user, group: "module_design", bucket: "ruby_rails")
      described_class.start!(user, concept: "memoization", bucket: "ruby_rails")

      described_class.start!(user, concept: "shallow_module", bucket: "ruby_rails")

      expect(row("shallow_module").drill_group).to eq("module_design")
      expect(described_class.for(user).count).to eq(2)
    end

    it "rejoins a member to its group when the group is drilled" do
      described_class.start_group!(user, group: "module_design", bucket: "ruby_rails")
      row("shallow_module").update!(drilled_at: nil, drill_group: nil)

      described_class.start!(user, concept: "shallow_module", bucket: "ruby_rails")

      expect(row("shallow_module").drill_group).to eq("module_design")
      expect(described_class.for(user).count).to eq(1)
    end

    it "returns false and changes nothing for a concept already drilled" do
      described_class.start!(user, concept: "n_plus_one", bucket: "ruby_rails")

      expect(described_class.start!(user, concept: "n_plus_one", bucket: "ruby_rails")).to be(false)
    end

    it "re-drilling an already drilled concept does not count against the cap" do
      described_class.start!(user, concept: "n_plus_one", bucket: "ruby_rails")
      described_class.start!(user, concept: "n_plus_one", bucket: "ruby_rails")

      expect { described_class.start!(user, concept: "memoization", bucket: "ruby_rails") }.not_to raise_error
    end
  end

  describe ".start_group!" do
    it "drills every concept in the group that the bucket holds, labelled with the group" do
      described_class.start_group!(user, group: "module_design", bucket: "ruby_rails")

      ConceptVocabulary::MODULE_DESIGN_CONCEPTS.each do |concept|
        expect(row(concept).drill_group).to eq("module_design")
        expect(row(concept).drilled_at).to be_present
      end
    end

    it "counts as one drill however many concepts it holds" do
      described_class.start_group!(user, group: "data_modeling", bucket: "ruby_rails")

      expect { described_class.start!(user, concept: "n_plus_one", bucket: "ruby_rails") }.not_to raise_error
      expect { described_class.start!(user, concept: "memoization", bucket: "ruby_rails") }
        .to raise_error(ConceptDrills::LimitReached)
    end

    it "absorbs lone drills of its own members rather than counting them against the cap" do
      described_class.start!(user, concept: "shallow_module", bucket: "ruby_rails")
      described_class.start!(user, concept: "pass_through_method", bucket: "ruby_rails")

      expect { described_class.start_group!(user, group: "module_design", bucket: "ruby_rails") }.not_to raise_error
      expect(described_class.for(user).count).to eq(1)
    end

    it "counts drills in other buckets against the cap" do
      described_class.start!(user, concept: "n_plus_one", bucket: "ruby_rails")
      described_class.start!(user, concept: "sync_vs_async", bucket: "architecture")

      expect { described_class.start_group!(user, group: "module_design", bucket: "ruby_rails") }
        .to raise_error(ConceptDrills::LimitReached)
    end

    it "returns false and leaves every member untouched when the group is already drilled" do
      described_class.start_group!(user, group: "module_design", bucket: "ruby_rails")
      row("shallow_module").update!(drilled_at: nil, drill_group: nil)
      stamps = user.concept_masteries.drilling.pluck(:concept, :drilled_at)

      expect(described_class.start_group!(user, group: "module_design", bucket: "ruby_rails")).to be(false)
      expect(user.concept_masteries.drilling.pluck(:concept, :drilled_at)).to match_array(stamps)
      expect(row("shallow_module").drilled_at).to be_nil
    end

    it "leaves a paused member paused, since no page stated the tradeoff for it" do
      user.concept_masteries.create!(concept: "shallow_module", language: "ruby_rails", tier: :paused, cooldown_remaining: 2)

      described_class.start_group!(user, group: "module_design", bucket: "ruby_rails")

      expect(row("shallow_module").tier).to eq("paused")
      expect(row("shallow_module").drilled_at).to be_present
    end

    it "refuses a group the bucket does not hold" do
      expect { described_class.start_group!(user, group: "module_design", bucket: "architecture") }
        .to raise_error(ArgumentError)
    end
  end

  describe "#can_start? and #can_start_group?" do
    it "follows what start! and start_group! would accept, cap included" do
      described_class.start_group!(user, group: "module_design", bucket: "ruby_rails")
      described_class.start!(user, concept: "memoization", bucket: "ruby_rails")
      row("shallow_module").update!(drilled_at: nil, drill_group: nil)

      drills = described_class.for(user)

      expect(drills).to be_full
      expect(drills.can_start?("shallow_module", "ruby_rails")).to be(true)
      expect(drills.can_start?("n_plus_one", "ruby_rails")).to be(false)
      expect(drills.can_start?("memoization", "ruby_rails")).to be(false)
      expect(drills.can_start_group?("module_design", "ruby_rails")).to be(false)
      expect(drills.can_start_group?("oo_design", "ruby_rails")).to be(false)
    end

    it "lets a group start that absorbs the lone drills filling the cap" do
      described_class.start!(user, concept: "shallow_module", bucket: "ruby_rails")
      described_class.start!(user, concept: "pass_through_method", bucket: "ruby_rails")

      expect(described_class.for(user).can_start_group?("module_design", "ruby_rails")).to be(true)
    end
  end

  describe ".stop! and .stop_group!" do
    it "stops the whole group when the concept is drilled as a member, and says which" do
      described_class.start_group!(user, group: "module_design", bucket: "ruby_rails")

      expect(described_class.stop!(user, concept: "shallow_module", bucket: "ruby_rails")).to eq("module_design")
      expect(user.concept_masteries.drilling).to be_empty
    end

    it "returns nil when stopping a lone drill" do
      described_class.start!(user, concept: "n_plus_one", bucket: "ruby_rails")

      expect(described_class.stop!(user, concept: "n_plus_one", bucket: "ruby_rails")).to be_nil
    end

    it "clears one concept's drill" do
      described_class.start!(user, concept: "n_plus_one", bucket: "ruby_rails")
      described_class.stop!(user, concept: "n_plus_one", bucket: "ruby_rails")

      expect(row("n_plus_one").drilled_at).to be_nil
    end

    it "clears every concept still drilled under the group" do
      described_class.start_group!(user, group: "module_design", bucket: "ruby_rails")
      described_class.stop_group!(user, group: "module_design", bucket: "ruby_rails")

      expect(user.concept_masteries.drilling).to be_empty
    end
  end

  describe "MAX_CONCURRENT" do
    it "is two" do
      expect(described_class::MAX_CONCURRENT).to eq(2)
    end

    it "leaves a non-fourth host free on the fullest possible day" do
      reachable_pairs  = ExerciseSection.all.combination(2).reject { |pair| pair.count(&:fourth?) > 1 }
      non_fourth_slots = reachable_pairs.map { |pair| ExerciseSection.layout(daily: pair).count { |_slot, kinds| kinds.none?(&:fourth?) } }.min
      fullest_day_hosts = [ non_fourth_slots, ExerciseSection::MAX_SECTIONS ].min

      expect(described_class::MAX_CONCURRENT).to be < fullest_day_hosts
    end
  end

  describe ".for" do
    it "lists a group once with the concepts still under it, and a lone concept by itself" do
      described_class.start_group!(user, group: "module_design", bucket: "ruby_rails")
      described_class.start!(user, concept: "n_plus_one", bucket: "ruby_rails")
      row(ConceptVocabulary::MODULE_DESIGN_CONCEPTS.first).update!(drilled_at: nil, drill_group: nil)

      drills = described_class.for(user)

      expect(drills.count).to eq(2)
      expect(drills).to be_full
      group = drills.entries.find { |entry| entry.group == "module_design" }
      expect(group.concepts).to match_array(ConceptVocabulary::MODULE_DESIGN_CONCEPTS.drop(1))
      expect(group.bucket).to eq("ruby_rails")
      expect(drills.drilling?("n_plus_one", "ruby_rails")).to be(true)
      expect(drills.group_for("n_plus_one", "ruby_rails")).to be_nil
      expect(drills.group_for(ConceptVocabulary::MODULE_DESIGN_CONCEPTS.last, "ruby_rails")).to eq("module_design")
      expect(drills.group_drilling?("module_design", "ruby_rails")).to be(true)
      expect(drills.group_drilling?("oo_design", "ruby_rails")).to be(false)
    end

    it "ignores a drill outside the user's current slice, so it neither counts nor strands a slot" do
      user.update!(language: "mixed")
      described_class.start!(user, concept: "prototype_chain", bucket: "javascript")
      user.update!(language: "ruby_rails")

      drills = described_class.for(user)

      expect(drills.entries).to eq([])
      expect(drills.drilling?("prototype_chain", "javascript")).to be(false)
    end

    it "is empty and not full for a user who has never drilled" do
      drills = described_class.for(user)

      expect(drills.entries).to eq([])
      expect(drills).not_to be_full
    end

    describe "accepted intent during an unfinished review" do
      let(:bucket) { "ruby_rails" }

      def partial(concept, date: Date.current, grade: "strong")
        exercise = user.daily_exercises.create!(date: date, generated_at: Time.current, language: bucket,
          problem_set: %w[code_review pattern].index_with { { "concept" => concept } })
        response = user.daily_responses.create!(date: date, daily_exercise: exercise, submitted_at: Time.current,
          answers: %w[code_review pattern].index_with { "An answer" },
          section_ratings: %w[code_review pattern].index_with { "right_level" },
          concept_tags: %w[code_review pattern].index_with { concept })
        apply_review(response, "pattern" => grade)
        response
      end

      def apply_review(response, grades)
        reviewer = double(review_sections: grades.transform_values { |grade| { ok: true, review: { "rating" => grade } } })
        allow(ConceptMastery).to receive(:record_review!).and_wrap_original { |method, *args, **kwargs| method.call(*args, **kwargs, initiate: true) }
        ResponseReview.new(response, user: user, reviewer: reviewer).call
      end

      def start(concept) = described_class.start!(user, concept: concept, bucket: bucket)
      def stop(concept) = described_class.stop!(user, concept: concept, bucket: bucket)
      def drills = described_class.for(user)

      it "reserves a provisional clear before admitting another request" do
        start("n_plus_one")
        start("memoization")
        response = partial("n_plus_one")
        expect { start("transaction_safety") }.to raise_error(ConceptDrills::LimitReached)
        expect(drills.count).to eq(2)
        expect(drills.reserved?("n_plus_one", bucket)).to be(true)
        expect(row("n_plus_one").drilled_at).to be_nil
        apply_review(response, "code_review" => "developing")
        expect(row("n_plus_one").drilled_at).to be_present
        expect(drills.count).to eq(2)
      end

      it "releases a reservation on Stop and never resurrects it after admitting another request" do
        start("n_plus_one")
        start("memoization")
        response = partial("n_plus_one")
        stop("n_plus_one")
        expect(start("transaction_safety")).to be(true)
        apply_review(response, "code_review" => "developing")
        expect(row("n_plus_one").drilled_at).to be_nil
        expect(drills.entries.flat_map(&:concepts)).to contain_exactly("memoization", "transaction_safety")
      end

      it "keeps reserved repeats inactive, but retains a later explicit restart's timestamp" do
        start("n_plus_one")
        response = partial("n_plus_one")
        expect(start("n_plus_one")).to be(false)
        expect(row("n_plus_one").drilled_at).to be_nil
        stop("n_plus_one")
        travel 2.hours do
          start("n_plus_one")
          stamp = row("n_plus_one").drilled_at
          apply_review(response, "code_review" => "developing")
          expect(row("n_plus_one").drilled_at).to eq(stamp)
        end
      end

      it "counts mixed active/reserved group members once and stops all of them" do
        described_class.start_group!(user, group: "module_design", bucket: bucket)
        start("memoization")
        response = partial("shallow_module")
        expect(drills.count).to eq(2)
        expect(drills.entries.find { |entry| entry.group == "module_design" }.reserved_concepts).to eq(%w[shallow_module])
        expect(stop("shallow_module")).to eq("module_design")
        apply_review(response, "code_review" => "developing")
        expect(drills.entries.flat_map(&:concepts)).to eq(%w[memoization])
      end

      it "does not let a delayed group stop reach a member restarted alone" do
        described_class.start_group!(user, group: "module_design", bucket: bucket)
        response = partial("shallow_module")
        described_class.stop_group!(user, group: "module_design", bucket: bucket)
        start("shallow_module")
        stamp = row("shallow_module").drilled_at
        described_class.stop_group!(user, group: "module_design", bucket: bucket)
        apply_review(response, "code_review" => "developing")
        expect(row("shallow_module")).to have_attributes(drilled_at: stamp, drill_group: nil)
      end

      it "absorbs a reserved lone request into a new group without resurrecting its old identity" do
        start("shallow_module")
        start("memoization")
        response = partial("shallow_module")
        expect(described_class.start_group!(user, group: "module_design", bucket: bucket)).to be(true)
        apply_review(response, "code_review" => "developing")
        expect(row("shallow_module").drill_group).to eq("module_design")
        expect(drills.count).to eq(2)
      end

      it "holds an entirely reserved group as one slot and lets a cleared member rejoin it" do
        described_class.start_group!(user, group: "module_design", bucket: bucket)
        concepts = described_class.concepts_in("module_design", bucket)
        responses = concepts.each_with_index.map { |concept, index| partial(concept, date: Date.current + index) }
        start("memoization")
        expect(drills.entries.find { |entry| entry.group == "module_design" }.reserved_concepts).to match_array(concepts)
        expect { start("transaction_safety") }.to raise_error(ConceptDrills::LimitReached)
        expect(described_class.start_group!(user, group: "module_design", bucket: bucket)).to be(false)
        expect(user.concept_masteries.where(concept: concepts).drilling).to be_empty
        apply_review(responses.first, "code_review" => "strong")
        expect(start(concepts.first)).to be(true)
        expect(row(concepts.first).drill_group).to eq("module_design")
        expect(drills.count).to eq(2)
        described_class.stop_group!(user, group: "module_design", bucket: bucket)
        responses.drop(1).each { |response| apply_review(response, "code_review" => "developing") }
        expect(drills.entries.flat_map(&:concepts)).to eq(%w[memoization])
      end

      it "retains active repeat intent without restamping or re-adding a cleared group member" do
        described_class.start_group!(user, group: "module_design", bucket: bucket)
        first = partial("shallow_module")
        apply_review(first, "code_review" => "strong")
        second = partial("pass_through_method", date: Date.current + 1, grade: "developing")
        stamp = row("pass_through_method").drilled_at
        expect(described_class.start_group!(user, group: "module_design", bucket: bucket)).to be(false)
        apply_review(second, "code_review" => "strong")
        expect(row("pass_through_method").drilled_at).to eq(stamp)
        expect(row("shallow_module").drilled_at).to be_nil
      end

      it "uses a later concept Stop to stop a restarted lone request" do
        described_class.start_group!(user, group: "module_design", bucket: bucket)
        response = partial("shallow_module")
        stop("shallow_module")
        start("shallow_module")
        stop("shallow_module")
        apply_review(response, "code_review" => "developing")
        expect(drills).not_to be_any
      end

      [ false, true ].each do |group_start|
        it "retains #{group_start ? 'group' : 'single'} start pause semantics after correction" do
          user.concept_masteries.create!(concept: "shallow_module", language: bucket,
            tier: :reduced, streak: 1, last_rating: "developing")
          response = partial("shallow_module")
          if group_start
            described_class.start_group!(user, group: "module_design", bucket: bucket)
          else
            start("shallow_module")
          end
          stamp = row("shallow_module").drilled_at
          apply_review(response, "code_review" => "developing")
          expect(row("shallow_module")).to have_attributes(tier: group_start ? "paused" : "reduced",
            cooldown_remaining: group_start ? 2 : 0, drilled_at: stamp)
        end
      end

      it "honors reservations and explicit releases when the returning writer's default is off" do
        stub_const("ConceptMastery::INITIATE_RECONCILIATION", false)
        start("n_plus_one")
        start("memoization")
        response = partial("n_plus_one")
        expect(ConceptMastery::INITIATE_RECONCILIATION).to be(false)
        expect { start("transaction_safety") }.to raise_error(ConceptDrills::LimitReached)
        stop("n_plus_one")
        start("transaction_safety")
        allow(ConceptMastery).to receive(:record_review!).and_call_original
        reviewer = double(review_sections: { "code_review" => { ok: true, review: { "rating" => "developing" } } })
        expect(ResponseReview.new(response, user: user, reviewer: reviewer).call.status).to eq(:ready)
        expect(drills.count).to eq(2)
        expect(row("n_plus_one").drilled_at).to be_nil
      end

      [ :group, :member ].each do |route|
        it "releases every member of an entirely reserved group through the #{route} Stop" do
          described_class.start_group!(user, group: "module_design", bucket: bucket)
          concepts = described_class.concepts_in("module_design", bucket)
          responses = concepts.each_with_index.map { |concept, index| partial(concept, date: Date.current + index) }
          expect(user.concept_masteries.drilling).to be_empty
          expect(drills.count).to eq(1)
          if route == :group
            described_class.stop_group!(user, group: "module_design", bucket: bucket)
          else
            stop(concepts.first)
          end
          responses.each { |response| apply_review(response, "code_review" => "developing") }
          expect(drills).not_to be_any
          expect(user.concept_masteries.drilling).to be_empty
        end
      end

      [ nil, [], "bad", false, 1, { "version" => 999 } ].each do |bad|
        it "refuses malformed reservation state #{bad.inspect} instead of showing spare capacity" do
          start("n_plus_one")
          target = row("n_plus_one")
          quoted = ConceptMastery.connection.quote(bad.to_json)
          ConceptMastery.where(id: target.id).update_all("drilled_at = NULL, review_reconciliation = #{quoted}::jsonb")
          expect { drills }.to raise_error(ArgumentError)
          expect { start("memoization") }.to raise_error(ArgumentError)
          expect(row("memoization")).to be_nil
        end
      end
    end
  end
end
