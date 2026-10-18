require "rails_helper"

RSpec.describe KindPreferences do
  # A stand-in rather than a record: needing the database would hide that this is built from plain values.
  def stated(weights: {}, excluded: [])
    Struct.new(:section_kind_weights, :excluded_section_kinds).new(weights, excluded)
  end

  let(:challenge) { ExerciseSection::Challenge }
  let(:parsons)   { ExerciseSection::ParsonsProblem }

  describe "#multiplier_for" do
    it "defaults a kind the user has not touched" do
      expect(described_class.none.multiplier_for(challenge)).to eq(1.0)
    end

    it "returns a stated stop" do
      preferences = described_class.new(weights: { "challenge" => 4.0 }, excluded: [])

      expect(preferences.multiplier_for(challenge)).to eq(4.0)
    end

    it "leaves other kinds at the default" do
      preferences = described_class.new(weights: { "challenge" => 4.0 }, excluded: [])

      expect(preferences.multiplier_for(parsons)).to eq(1.0)
    end

    # A zero would make a kind unpickable and a negative would corrupt every other kind's share.
    it "falls back to the default for a value outside the stops" do
      [ 0, -1, 3.0, "0.5", nil ].each do |junk|
        preferences = described_class.new(weights: { "challenge" => junk }, excluded: [])

        expect(preferences.multiplier_for(challenge)).to eq(1.0)
      end
    end
  end

  describe "#excluded?" do
    it "is true only for a kind the user excluded" do
      preferences = described_class.new(weights: {}, excluded: [ "challenge" ])

      expect(preferences.excluded?(challenge)).to be(true)
      expect(preferences.excluded?(parsons)).to be(false)
    end

    it "is false for everything when nothing is stated" do
      expect(ExerciseSection.rotatable(daily: DailyKinds::DEFAULT)).to all(satisfy { |kind| !described_class.none.excluded?(kind) })
    end
  end

  describe ".for" do
    it "treats a user who has stated nothing as no preferences at all" do
      preferences = described_class.for(stated)

      ExerciseSection.rotatable(daily: DailyKinds::DEFAULT).each do |kind|
        expect(preferences.multiplier_for(kind)).to eq(described_class::DEFAULT_MULTIPLIER)
        expect(preferences.excluded?(kind)).to be(false)
      end
    end

    it "reads both stated columns" do
      preferences = described_class.for(stated(weights: { "challenge" => 0.25 }, excluded: [ "parsons_problem" ]))

      expect(preferences.multiplier_for(challenge)).to eq(0.25)
      expect(preferences.excluded?(parsons)).to be(true)
    end
  end

  # The signature keeps tier state unreachable, so a preference can never become a mastery readout.
  it "is constructed from stated preference alone" do
    expect(described_class.instance_method(:initialize).parameters)
      .to eq([ [ :keyreq, :weights ], [ :keyreq, :excluded ] ])
  end

  describe "#eligible" do
    it "drops excluded kinds, and falls back to every kind when exclusion would empty the pool" do
      preferences = described_class.new(weights: {}, excluded: %w[challenge parsons_problem])

      expect(preferences.eligible([ ExerciseSection::Challenge, ExerciseSection::Architecture ])).to eq([ ExerciseSection::Architecture ])
      expect(preferences.eligible([ ExerciseSection::Challenge, ExerciseSection::ParsonsProblem ]))
        .to eq([ ExerciseSection::Challenge, ExerciseSection::ParsonsProblem ])
    end
  end

  describe "#all_excluded?" do
    it "is the one test for a pool exclusion would empty, read by the fallback and the emptied-slot refusal" do
      preferences = described_class.new(weights: {}, excluded: %w[challenge parsons_problem])

      expect(preferences.all_excluded?([ ExerciseSection::Challenge, ExerciseSection::ParsonsProblem ])).to be(true)
      expect(preferences.all_excluded?([ ExerciseSection::Challenge, ExerciseSection::Architecture ])).to be(false)
    end
  end

  describe "#offered" do
    it "offers a slot whose every kind is excluded, as rotation still fills it" do
      preferences = described_class.new(weights: {}, excluded: %w[architecture security_review parsons_problem])
      daily = [ ExerciseSection::Challenge, ExerciseSection::CodeReview ]

      expect(preferences.offered(daily: daily))
        .to include(ExerciseSection::Architecture, ExerciseSection::SecurityReview, ExerciseSection::ParsonsProblem)
    end


    it "keeps a daily kind the user excluded and drops an excluded optional kind" do
      preferences = described_class.new(weights: {}, excluded: %w[architecture challenge])
      daily = [ ExerciseSection::Architecture, ExerciseSection::CodeReview ]

      expect(preferences.offered(daily: daily)).to include(ExerciseSection::Architecture)
      expect(preferences.offered(daily: daily)).not_to include(ExerciseSection::Challenge)
    end

    it "is every kind but the excluded ones for the default pair" do
      preferences = described_class.new(weights: {}, excluded: %w[challenge])

      expect(preferences.offered(daily: DailyKinds::DEFAULT)).to eq(ExerciseSection.all - [ ExerciseSection::Challenge ])
    end
  end
end
