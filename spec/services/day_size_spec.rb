require "rails_helper"

RSpec.describe DaySize do
  def gate(count, reason = :held, evidence: {})
    CompetencyGate::Plan.new(count: count, reason: reason, evidence: evidence)
  end

  def size(setting: nil, completion: 4, gate: gate(4))
    described_class.for(setting: setting, completion: completion, gate: gate)
  end

  describe "a fixed setting" do
    it "returns the setting, whatever completion and the gate say" do
      decision = size(setting: 4, completion: 2, gate: gate(2))

      expect(decision.count).to eq(4)
      expect(decision.reason).to eq(:setting)
    end

    it "ignores the brake" do
      decision = size(setting: 3, completion: 4, gate: gate(2, :brake))

      expect(decision.count).to eq(3)
      expect(decision.reason).to eq(:setting)
    end

    # The model validates the count only when it changes, so an old row can sit outside the current range.
    it "clamps a stored setting outside the current range" do
      expect(size(setting: ExerciseSection::MAX_SECTIONS + 1).count).to eq(ExerciseSection::MAX_SECTIONS)
      expect(size(setting: SectionCount::FLOOR - 1).count).to eq(SectionCount::FLOOR)
      expect(size(setting: SectionCount::FLOOR - 1).reason).to eq(:setting)
    end

    it "is not Automatic, so the coverage exception never applies" do
      expect(size(setting: 2).automatic?).to be(false)
      expect(size.automatic?).to be(true)
    end
  end

  describe "Automatic" do
    it "takes the gate when it is lower than completion" do
      decision = size(completion: 4, gate: gate(3))

      expect(decision.count).to eq(3)
      expect(decision.reason).to eq(:gate)
    end

    it "takes completion when it is lower than the gate" do
      decision = size(completion: 2, gate: gate(4, :grew))

      expect(decision.count).to eq(2)
      expect(decision.reason).to eq(:completion)
    end

    it "names completion when the two agree" do
      expect(size(completion: 3, gate: gate(3)).reason).to eq(:completion)
      expect(size(completion: 2, gate: gate(2, :brake)).reason).to eq(:completion)
    end

    it "names the brake when it is what lowers the day" do
      decision = size(completion: 4, gate: gate(2, :brake))

      expect(decision.count).to eq(SectionCount::FLOOR)
      expect(decision.reason).to eq(:brake)
    end

    it "clamps to the floor and the largest day" do
      expect(size(completion: 1, gate: gate(1)).count).to eq(SectionCount::FLOOR)
      expect(size(completion: 9, gate: gate(9)).count).to eq(ExerciseSection::MAX_SECTIONS)
    end
  end

  describe "#brake?" do
    # The coverage exception stays off while too-hard results remain in the window.
    it "follows the gate's reason, not which bound decided" do
      expect(size(completion: 2, gate: gate(2, :brake)).brake?).to be(true)
      expect(size(completion: 4, gate: gate(3, :grew)).brake?).to be(false)
    end

    it "is off under a fixed setting" do
      expect(size(setting: 2, gate: gate(2, :brake)).brake?).to be(false)
    end
  end

  describe "#diagnostics" do
    it "carries the decision and the gate's evidence" do
      evidence = { to_three: { required: 5, available: 1, bar_met: 1, favourable: 1, by_kind: { "code_review" => 1 } } }
      decision = size(completion: 4, gate: gate(2, :held, evidence: evidence))

      expect(decision.diagnostics).to eq(
        count: 2, reason: :gate, setting: "automatic", completion: 4,
        gate: { count: 2, reason: :held, evidence: evidence }
      )
    end
  end
end
