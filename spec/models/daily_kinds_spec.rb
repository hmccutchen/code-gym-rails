require "rails_helper"

RSpec.describe DailyKinds do
  def kinds(*keys) = keys.map { |key| ExerciseSection.find(key) }

  describe "DEFAULT and COUNT" do
    it "is the registry's default pair, and the count follows its size" do
      expect(described_class::DEFAULT).to eq(kinds("code_review", "design_comparison"))
      expect(described_class::COUNT).to eq(described_class::DEFAULT.size)
    end
  end

  describe ".for" do
    it "reads an untouched account's empty list as the default pair" do
      expect(described_class.for(User.new(daily_section_kinds: []))).to eq(described_class::DEFAULT)
    end

    it "keeps a stored pair in its stored order" do
      expect(described_class.for(User.new(daily_section_kinds: %w[architecture code_review])))
        .to eq(kinds("architecture", "code_review"))
    end
  end

  describe ".normalize" do
    it "fills a place a shorter list leaves with the first default kind not already held" do
      expect(described_class.normalize(%w[code_review])).to eq(kinds("code_review", "design_comparison"))
      expect(described_class.normalize(%w[design_comparison])).to eq(kinds("design_comparison", "code_review"))
      expect(described_class.normalize(%w[pattern])).to eq(kinds("pattern", "code_review"))
    end

    it "cuts a longer list from the end, so the first places keep their kinds" do
      expect(described_class.normalize(%w[pattern challenge plan_review])).to eq(kinds("pattern", "challenge"))
    end

    it "fills an unknown key's place the same way a missing place is filled" do
      expect(described_class.normalize(%w[retired_kind pattern])).to eq(kinds("code_review", "pattern"))
    end

    it "fills a repeated kind's second place the same way" do
      expect(described_class.normalize(%w[pattern pattern])).to eq(kinds("pattern", "code_review"))
    end

    it "fills a second fourth kind's place the same way, so a pair never holds two fourths" do
      expect(described_class.normalize(%w[plan_review ambiguity_hunt])).to eq(kinds("plan_review", "code_review"))
    end

    it "reads nil or a non-list as the default pair" do
      expect(described_class.normalize(nil)).to eq(described_class::DEFAULT)
      expect(described_class.normalize([ nil, 7 ])).to eq(described_class::DEFAULT)
    end
  end

  describe ".recorded" do
    it "reads the pair a row's plan recorded" do
      expect(described_class.recorded("daily_kinds" => %w[challenge design_comparison]))
        .to eq(kinds("challenge", "design_comparison"))
    end

    it "keeps the pair exactly as recorded, never fitted to today's count, so a past day is never reclassified" do
      stub_const("DailyKinds::COUNT", 3)

      expect(described_class.recorded("daily_kinds" => %w[challenge design_comparison]))
        .to eq(kinds("challenge", "design_comparison"))
      expect(described_class.recorded("daily_kinds" => %w[challenge retired_kind])).to eq(kinds("challenge"))
    end

    it "reads a row planned before the pair was recorded as the default pair" do
      expect(described_class.recorded({})).to eq(described_class::DEFAULT)
      expect(described_class.recorded("size" => 3)).to eq(described_class::DEFAULT)
    end
  end

  describe ".problems_with" do
    it "accepts the empty list and any full pair holding at most one fourth" do
      expect(described_class.problems_with([])).to eq([])
      expect(described_class.problems_with(%w[pattern design_comparison])).to eq([])
      expect(described_class.problems_with(%w[plan_review challenge])).to eq([])
    end

    it "refuses each malformed shape" do
      expect(described_class.problems_with("pattern")).to eq([ "must be a list" ])

      refused = [ %w[pattern], %w[pattern challenge architecture], %w[pattern retired_kind], [ "pattern", :challenge ],
                  %w[pattern pattern], %w[plan_review ambiguity_hunt] ]
      refused.each do |shape|
        expect(described_class.problems_with(shape))
          .to eq([ "must name 2 different section kinds, at most one of them a fourth-section kind" ]), shape.inspect
      end
    end
  end
end
