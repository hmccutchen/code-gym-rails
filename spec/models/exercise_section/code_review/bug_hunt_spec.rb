require "rails_helper"

RSpec.describe ExerciseSection::CodeReview::BugHunt do
  describe ".mode?" do
    it "is true for the bug_hunt mode only" do
      expect(described_class.mode?(:bug_hunt)).to be(true)
      expect(described_class.mode?(:application_code)).to be(false)
      expect(described_class.mode?(nil)).to be(false)
    end
  end

  describe ".section?" do
    it "reads a section with a purpose as a bug_hunt section" do
      expect(described_class.section?({ "purpose" => "Remove every even number." })).to be(true)
      expect(described_class.section?({ "snippet" => "x" })).to be(false)
      expect(described_class.section?(nil)).to be(false)
    end
  end
end

RSpec.describe ExerciseSection::CodeReview do
  describe "the planning and mastery hooks" do
    def section_for(mode)
      mode == :bug_hunt ? { "purpose" => "Remove every even number.", "snippet" => "x" } : { "snippet" => "x" }
    end

    it "agree for every mode: a section that is not mastery evidence is never planned onto" do
      %i[application_code test_file schema_review bug_hunt].each do |mode|
        expect(described_class.planning_host?(mode: mode)).to eq(described_class.mastery_evidence?(section_for(mode))), mode.to_s
      end
    end

    it "keep bug_hunt out of both" do
      expect(described_class.planning_host?(mode: :bug_hunt)).to be(false)
      expect(described_class.mastery_evidence?(section_for(:bug_hunt))).to be(false)
    end

    it "leave every other kind a planning host and mastery evidence" do
      (ExerciseSection.all - [ described_class ]).each do |kind|
        expect(kind.planning_host?(mode: :bug_hunt)).to be(true)
        expect(kind.mastery_evidence?({ "snippet" => "x" })).to be(true)
      end
    end
  end

  describe ".bug_hunt?" do
    it "reads the purpose field" do
      expect(described_class.bug_hunt?({ "purpose" => "Sum the prices." })).to be(true)
      expect(described_class.bug_hunt?({ "snippet" => "x" })).to be(false)
    end
  end
end
