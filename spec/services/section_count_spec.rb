require "rails_helper"

RSpec.describe SectionCount do
  def history(*answered)
    answered.map { |count| ExerciseHistoryEntry.new(section_keys: [], answered: count) }
  end

  it "gives a new user the full set until there is evidence" do
    expect(described_class.for(history(4, 4))).to eq(ExerciseSection.slot_count)
  end

  it "keeps a consistent finisher at the full set" do
    expect(described_class.for(history(4, 4, 4, 4, 4))).to eq(4)
  end

  it "stretches one past what the engineer reliably finishes" do
    expect(described_class.for(history(2, 2, 2, 2, 2))).to eq(3)
  end

  # Without the stretch this is an absorbing state: 2-of-2 forever reads as a
  # mean of 2 and the day can never grow back.
  it "grows back after a full short day" do
    expect(described_class.for(history(3, 3, 3, 3, 3))).to eq(4)
  end

  it "never drops below the floor" do
    expect(described_class.for(history(0, 0, 0, 1, 0))).to eq(described_class::FLOOR)
  end

  it "counts a skipped exercise as zero" do
    expect(described_class.for(history(nil, nil, 4, 4, 4))).to eq(3)
  end

  it "floors out a long absence rather than compounding it" do
    five_skips = history(nil, nil, nil, nil, nil) + history(4, 4, 4, 4, 4)
    ten_skips  = history(*Array.new(10, nil)) + history(4, 4, 4, 4, 4)

    expect(described_class.for(five_skips)).to eq(3)
    expect(described_class.for(ten_skips)).to eq(3)
  end

  it "counts scattered skips in full, unlike a consecutive run" do
    expect(described_class.for(history(nil, 4, nil, 4, nil, 4))).to eq(3)
  end

  describe "the hard override" do
    it "returns the full set without consulting history" do
      history = spy("history")

      expect(described_class.for(history, adaptive: false)).to eq(ExerciseSection.slot_count)
      expect(history).not_to have_received(:first)
    end
  end
end
