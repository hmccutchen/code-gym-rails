require "rails_helper"

RSpec.describe KindDifficulty do
  # A stand-in rather than a record, as in kind_preferences_spec: this object is
  # built from plain values, and a spec that needed the database would hide that.
  def stated(levels: {}, locked: [])
    Struct.new(:section_kind_levels, :locked_section_kinds).new(levels, locked)
  end

  let(:code_review) { ExerciseSection::CodeReview }
  let(:challenge)   { ExerciseSection::Challenge }

  describe "#level_for" do
    it "is nil for a kind the user has not targeted" do
      expect(described_class.none.level_for(challenge)).to be_nil
    end

    it "returns a stated level, including for a kind that does not rotate" do
      difficulty = described_class.new(levels: { "code_review" => "senior" }, locked: [])

      expect(difficulty.level_for(code_review)).to eq("senior")
    end

    it "reads a value outside LEVELS as unset" do
      [ "expert", "", nil, 3, "Senior" ].each do |junk|
        difficulty = described_class.new(levels: { "challenge" => junk }, locked: [])

        expect(difficulty.level_for(challenge)).to be_nil
      end
    end
  end

  describe "#locked?" do
    it "is true for a locked kind with a level" do
      difficulty = described_class.new(levels: { "challenge" => "junior" }, locked: [ "challenge" ])

      expect(difficulty.locked?(challenge)).to be(true)
    end

    # The read-side half of the lock-needs-a-level invariant. A console write
    # can leave this state behind; it must never suppress easing.
    it "reads an orphaned lock as unlocked" do
      difficulty = described_class.new(levels: {}, locked: [ "challenge" ])

      expect(difficulty.locked?(challenge)).to be(false)
    end

    it "reads a lock on an invalid level as unlocked" do
      difficulty = described_class.new(levels: { "challenge" => "expert" }, locked: [ "challenge" ])

      expect(difficulty.locked?(challenge)).to be(false)
    end
  end

  describe "#targeted_kinds" do
    it "lists only kinds with a valid level, in registry order" do
      difficulty = described_class.new(levels: { "challenge" => "senior", "code_review" => "junior", "pattern" => "x" }, locked: [])

      expect(difficulty.targeted_kinds).to eq([ code_review, challenge ])
    end
  end

  describe ".for" do
    it "reads both stated columns" do
      difficulty = described_class.for(stated(levels: { "pattern" => "principal_engineer" }, locked: [ "pattern" ]))

      expect(difficulty.level_for(ExerciseSection::Pattern)).to eq("principal_engineer")
      expect(difficulty.locked?(ExerciseSection::Pattern)).to be(true)
    end
  end

  describe "LEVELS" do
    # Skill levels are these levels, so they are held to that rather than kept
    # apart; the rating scales stay apart from both.
    it "shares no value with either rating scale" do
      [ DailyResponse::DIFFICULTY_LEVELS, ConceptMastery::AI_RATING_RANK.keys ].each do |scale|
        expect(described_class::LEVELS & scale).to be_empty
      end
    end

    it "is the skill levels, in the same order" do
      expect(User::SKILL_LEVELS).to eq(described_class::LEVELS)
    end

    it "has exactly one fallback definition per level" do
      expect(described_class::LEVEL_DEFINITIONS.keys).to eq(described_class::LEVELS)
    end
  end

  it "is constructed from stated preference alone" do
    expect(described_class.instance_method(:initialize).parameters)
      .to eq([ [ :keyreq, :levels ], [ :keyreq, :locked ] ])
  end
end

RSpec.describe KindDifficulty, "#rung_for" do
  let(:challenge) { ExerciseSection::Challenge }

  it "reads a skill level outside the scale as junior rather than raising, like the class's other readers" do
    expect(described_class.none.rung_for(challenge, skill_level: "intermediate")).to eq("junior")
  end

  it "pitches every skill level at the rung of the same name" do
    User::SKILL_LEVELS.each do |skill_level|
      expect(described_class.none.rung_for(challenge, skill_level: skill_level)).to eq(skill_level)
    end
  end

  it "answers the target when one is set, else the skill level's rung" do
    targeted = described_class.new(levels: { "challenge" => "principal_engineer" }, locked: [])

    expect(targeted.rung_for(challenge, skill_level: "junior")).to eq("principal_engineer")
    expect(described_class.none.rung_for(challenge, skill_level: "junior")).to eq("junior")
    expect(described_class.none.rung_for(challenge, skill_level: "senior")).to eq("senior")
    expect(described_class.none.rung_for(challenge, skill_level: "principal_engineer")).to eq("principal_engineer")
  end
end
