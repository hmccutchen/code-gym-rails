require "rails_helper"

RSpec.describe SectionCount do
  def history(*answered)
    answered.map do |count|
      delivered_section_keys = Array.new(count.to_i, "section")
      ExerciseHistoryEntry::Completion.new(delivered_section_keys: delivered_section_keys,
        answered: count, dropped: 0)
    end
  end

  def exercise_history_entry(section_keys:, delivered_section_keys:, answered:, dropped:)
    ExerciseHistoryEntry::Completion.new(delivered_section_keys: delivered_section_keys,
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

  # Without the stretch, 2-of-2 forever reads as a mean of 2 and the day never grows back.
  it "grows back after a full short day" do
    expect(described_class.for(history(3, 3, 3, 3, 3))).to eq(4)
  end

  it "never drops below the floor" do
    expect(described_class.for(history(1, 1, 1, 1, 1))).to eq(described_class::FLOOR)
  end

  it "uses only the most recent qualified completion window" do
    expect(described_class.for(history(1, 1, 1, 1, 1, 4, 4, 4))).to eq(2)
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
  end
end
