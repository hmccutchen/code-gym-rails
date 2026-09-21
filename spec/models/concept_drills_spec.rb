require "rails_helper"

RSpec.describe ConceptDrills do
  let(:user) { User.create!(email: "drills@example.com", name: "Drills") }

  def row(concept, bucket = "ruby_rails")
    user.concept_masteries.find_by(concept: concept, language: bucket)
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
      row("shallow_module").clear_drill!

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

      AiService::MODULE_DESIGN_CONCEPTS.each do |concept|
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

    it "refuses a group the bucket does not hold" do
      expect { described_class.start_group!(user, group: "module_design", bucket: "architecture") }
        .to raise_error(ArgumentError)
    end
  end

  describe ".stop! and .stop_group!" do
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
    it "is one fewer than the slots that can host a drilled concept" do
      hosting_slots = ExerciseSection.slots.count { |_slot, kinds| kinds.none?(&:fourth?) }

      expect(described_class::MAX_CONCURRENT).to eq(hosting_slots - 1)
      expect(described_class::MAX_CONCURRENT).to eq(2)
    end
  end

  describe ".for" do
    it "lists a group once with the concepts still under it, and a lone concept by itself" do
      described_class.start_group!(user, group: "module_design", bucket: "ruby_rails")
      described_class.start!(user, concept: "n_plus_one", bucket: "ruby_rails")
      row(AiService::MODULE_DESIGN_CONCEPTS.first).update!(drilled_at: nil, drill_group: nil)

      drills = described_class.for(user)

      expect(drills.count).to eq(2)
      expect(drills).to be_full
      group = drills.entries.find { |entry| entry.group == "module_design" }
      expect(group.concepts).to match_array(AiService::MODULE_DESIGN_CONCEPTS.drop(1))
      expect(group.bucket).to eq("ruby_rails")
      expect(drills.drilling?("n_plus_one", "ruby_rails")).to be(true)
      expect(drills.group_for("n_plus_one", "ruby_rails")).to be_nil
      expect(drills.group_for(AiService::MODULE_DESIGN_CONCEPTS.last, "ruby_rails")).to eq("module_design")
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
  end
end
