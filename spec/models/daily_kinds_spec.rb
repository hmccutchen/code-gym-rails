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

    it "holds only the pair under Automatic or 2, whatever extra sections are stored" do
      stored = %w[code_review design_comparison pattern challenge]

      expect(described_class.for(User.new(daily_section_kinds: stored))).to eq(kinds("code_review", "design_comparison"))
      expect(described_class.for(User.new(daily_section_kinds: stored, daily_section_count: 2)))
        .to eq(kinds("code_review", "design_comparison"))
    end

    it "holds the first place alone under a setting of 1" do
      user = User.new(daily_section_kinds: %w[design_comparison code_review], daily_section_count: 1)

      expect(described_class.for(user)).to eq(kinds("design_comparison"))
    end

    it "holds a chosen extra section for each place a larger setting adds" do
      stored = %w[code_review design_comparison pattern challenge]

      expect(described_class.for(User.new(daily_section_kinds: stored, daily_section_count: 3)))
        .to eq(kinds("code_review", "design_comparison", "pattern"))
      expect(described_class.for(User.new(daily_section_kinds: stored, daily_section_count: 4)))
        .to eq(kinds(*stored))
    end

    it "holds only the places stored when a larger setting has no extra sections chosen, so rotation fills the rest" do
      expect(described_class.for(User.new(daily_section_kinds: [], daily_section_count: 4))).to eq(described_class::DEFAULT)
    end
  end

  describe ".pair" do
    it "is the first two places whatever the setting, the places a card's swap control changes" do
      user = User.new(daily_section_kinds: %w[design_comparison code_review pattern], daily_section_count: 1)

      expect(described_class.pair(user)).to eq(kinds("design_comparison", "code_review"))
    end
  end

  describe ".shared_pair" do
    it "is the pair a day's kinds open with, or nothing for a one-section day, since one section shares with nothing" do
      expect(described_class.shared_pair(kinds("pattern", "code_review", "challenge"))).to eq(kinds("pattern", "code_review"))
      expect(described_class.shared_pair(kinds("pattern"))).to eq([])
    end
  end

  describe ".normalize" do
    it "fills a place a shorter list leaves with the first default kind not already held" do
      expect(described_class.normalize(%w[code_review])).to eq(kinds("code_review", "design_comparison"))
      expect(described_class.normalize(%w[design_comparison])).to eq(kinds("design_comparison", "code_review"))
      expect(described_class.normalize(%w[pattern])).to eq(kinds("pattern", "code_review"))
    end

    it "keeps places past the pair as chosen extra sections, up to the most a day holds" do
      expect(described_class.normalize(%w[pattern challenge plan_review])).to eq(kinds("pattern", "challenge", "plan_review"))
      expect(described_class.normalize(%w[code_review design_comparison pattern challenge architecture]))
        .to eq(kinds("code_review", "design_comparison", "pattern", "challenge"))
    end

    it "drops an extra section that repeats a kind, names a second fourth or names no kind, rather than filling it" do
      expect(described_class.normalize(%w[code_review design_comparison code_review challenge]))
        .to eq(kinds("code_review", "design_comparison", "challenge"))
      expect(described_class.normalize(%w[plan_review code_review ambiguity_hunt retired_kind]))
        .to eq(kinds("plan_review", "code_review"))
    end

    it "fills an unknown pair place from the defaults first, dropping an extra section that then repeats it" do
      expect(described_class.normalize(%w[pattern retired_kind code_review design_comparison]))
        .to eq(kinds("pattern", "code_review", "design_comparison"))
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

  describe ".place? and .stored" do
    it "accepts only an integer index into the pair, and stores the default pair as empty" do
      expect((0...described_class::COUNT).map { |place| described_class.place?(place) }).to all(be(true))
      expect([ -1, described_class::COUNT, "0", nil ].map { |place| described_class.place?(place) }).to all(be(false))
      expect(described_class.stored(described_class::DEFAULT.map(&:key))).to eq([])
      expect(described_class.stored(%w[architecture code_review])).to eq(%w[architecture code_review])
    end
  end

  describe ".conflict" do
    it "names the rule a kind would break beside the others, the one statement the swap and normalize share" do
      expect(described_class.conflict(ExerciseSection::CodeReview, kinds("code_review"))).to eq(:repeat)
      expect(described_class.conflict(ExerciseSection::AmbiguityHunt, kinds("plan_review"))).to eq(:second_fourth)
      expect(described_class.conflict(ExerciseSection::AmbiguityHunt, [ nil ])).to be_nil
      expect(described_class.conflict(ExerciseSection::Pattern, kinds("plan_review"))).to be_nil
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

    it "reads a pair whose every key has since been retired as empty, never as the default pair" do
      expect(described_class.recorded("daily_kinds" => %w[retired_kind other_retired_kind])).to eq([])
    end

    it "reads a row planned before the pair was recorded as the default pair" do
      expect(described_class.recorded({})).to eq(described_class::DEFAULT)
      expect(described_class.recorded("size" => 3)).to eq(described_class::DEFAULT)
    end
  end

  describe ".problems_with" do
    it "accepts the empty list and any full pair, with up to two extra sections, holding at most one fourth" do
      expect(described_class.problems_with([])).to eq([])
      expect(described_class.problems_with(%w[pattern design_comparison])).to eq([])
      expect(described_class.problems_with(%w[plan_review challenge])).to eq([])
      expect(described_class.problems_with(%w[code_review design_comparison pattern])).to eq([])
      expect(described_class.problems_with(%w[code_review design_comparison pattern plan_review])).to eq([])
    end

    it "refuses each malformed shape" do
      expect(described_class.problems_with("pattern")).to eq([ "must be a list" ])

      refused = [ %w[pattern], %w[pattern retired_kind], [ "pattern", :challenge ], %w[pattern pattern],
                  %w[plan_review ambiguity_hunt], %w[code_review design_comparison code_review],
                  %w[code_review plan_review ambiguity_hunt], %w[code_review design_comparison pattern challenge architecture] ]
      refused.each do |shape|
        expect(described_class.problems_with(shape))
          .to eq([ "must name 2 to 4 different section kinds, at most one of them from plan_review, ambiguity_hunt, pseudocode_to_code" ]), shape.inspect
      end
    end
  end
end
