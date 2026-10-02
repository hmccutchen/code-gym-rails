require "rails_helper"

RSpec.describe SectionCount do
  def history(*answered)
    answered.map do |count|
      delivered_section_keys = Array.new(count.to_i, "section")
      ExerciseHistoryEntry.new(section_keys: delivered_section_keys, delivered_section_keys: delivered_section_keys,
        answered: count, dropped: 0)
    end
  end

  def exercise_history_entry(section_keys:, delivered_section_keys:, answered:, dropped:)
    ExerciseHistoryEntry.new(section_keys: section_keys, delivered_section_keys: delivered_section_keys,
      answered: answered, dropped: dropped)
  end

  it "gives a new user the full set until there is evidence" do
    expect(described_class.for(history(4, 4))).to eq(ExerciseSection::MAX_SECTIONS)
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


  describe "with dropped sections" do
    it "lets a drop stand in for a delivered section left unanswered" do
      partial = exercise_history_entry(section_keys: %w[code_review pattern challenge plan_review],
        delivered_section_keys: %w[code_review pattern challenge], answered: 2, dropped: 1)

      expect(described_class.send(:credited_sections, partial)).to eq(3)
    end

    it "credits a drop when every delivered section was answered" do
      complete = exercise_history_entry(section_keys: %w[code_review pattern challenge plan_review],
        delivered_section_keys: %w[code_review pattern challenge], answered: 3, dropped: 1)

      expect(described_class.send(:credited_sections, complete)).to eq(3)
    end

    it "treats a no-response day as zero credit even when sections were dropped" do
      no_response = exercise_history_entry(section_keys: %w[code_review pattern challenge plan_review],
        delivered_section_keys: %w[code_review pattern challenge], answered: nil, dropped: 1)

      expect(described_class.send(:credited_sections, no_response)).to eq(0)
    end

    it "treats a day with nothing answered as zero credit even when sections were dropped" do
      untouched = exercise_history_entry(section_keys: %w[code_review pattern challenge plan_review],
        delivered_section_keys: %w[code_review pattern challenge], answered: 0, dropped: 1)

      expect(described_class.send(:credited_sections, untouched)).to eq(0)
    end

    it "never credits more than the delivered sections" do
      capped = exercise_history_entry(section_keys: %w[code_review pattern challenge plan_review],
        delivered_section_keys: %w[code_review pattern], answered: 1, dropped: 2)

      expect(described_class.send(:credited_sections, capped)).to eq(2)
      expect(described_class.for([ capped, capped, capped ])).to eq(3)
    end

    it "can shorten tomorrow when more sections were dropped than the engineer left unanswered" do
      half_delivered = exercise_history_entry(section_keys: %w[code_review pattern challenge plan_review],
        delivered_section_keys: %w[code_review pattern], answered: 2, dropped: 2)

      expect(described_class.for([ half_delivered, half_delivered, half_delivered ])).to eq(3)
    end

    it "sizes a day with a drop and one skipped section like a fully answered one" do
      full  = exercise_history_entry(section_keys: %w[code_review pattern challenge],
        delivered_section_keys: %w[code_review pattern challenge],
        answered: 3, dropped: 0)
      short = exercise_history_entry(section_keys: %w[code_review pattern challenge plan_review],
        delivered_section_keys: %w[code_review pattern challenge], answered: 2, dropped: 1)

      expect(described_class.for([ short, short, full ])).to eq(described_class.for([ full, full, full ]))
    end

    it "lets no-response rows count as zero in tomorrow's section count" do
      no_response = exercise_history_entry(section_keys: %w[code_review pattern challenge plan_review],
        delivered_section_keys: [ "code_review" ], answered: nil, dropped: 3)
      full = exercise_history_entry(section_keys: %w[code_review pattern challenge plan_review],
        delivered_section_keys: %w[code_review pattern challenge plan_review], answered: 4, dropped: 0)

      expect(described_class.for([ no_response, no_response, full ])).to eq(2)
    end
  end
end
