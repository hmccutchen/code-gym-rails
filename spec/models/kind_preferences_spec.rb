require "rails_helper"

RSpec.describe KindPreferences do
  # A stand-in rather than a record: this object is deliberately built from
  # plain values, and a spec that needed the database would hide that.
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

    # Totality matters more than strictness here: a zero would make a kind
    # unpickable below starvation, which is the failure mode this whole feature
    # is built to avoid, and a negative would corrupt every other kind's share
    # of the roll.
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
      expect(ExerciseSection.rotatable).to all(satisfy { |kind| !described_class.none.excluded?(kind) })
    end
  end

  describe ".for" do
    it "treats a user who has stated nothing as no preferences at all" do
      preferences = described_class.for(stated)

      ExerciseSection.rotatable.each do |kind|
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

  # The signature is the guarantee that a curation preference can never become a
  # readout of mastery: this object is handed stated preference and nothing
  # else, so tier state is not merely unused here — it is unreachable.
  it "is constructed from stated preference alone" do
    expect(described_class.instance_method(:initialize).parameters)
      .to eq([ [ :keyreq, :weights ], [ :keyreq, :excluded ] ])
  end
end
