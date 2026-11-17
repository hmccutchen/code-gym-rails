require "rails_helper"

RSpec.describe NoteQuestion do
  let(:sections) { %w[code_review design_comparison pattern] }

  def pick(cleared: [], duck_turns: [], too_hard: [], skipped: [])
    described_class.pick(sections: sections, cleared: cleared, duck_turns: duck_turns, too_hard: too_hard, skipped: skipped)
  end

  it "asks why the engineer started over when a section's duck thread was cleared, ahead of every other signal" do
    chosen = pick(cleared: %w[pattern], duck_turns: %w[code_review], too_hard: %w[code_review], skipped: %w[design_comparison])

    expect(chosen.key).to eq("cleared:pattern")
    expect(described_class.text(chosen)).to eq("You started over with the thinking partner on Pattern of the Month. What made you start again?")
  end

  it "asks what was unclear when a section has duck turns and none was cleared" do
    chosen = pick(duck_turns: %w[design_comparison], too_hard: %w[code_review])

    expect(described_class.text(chosen)).to eq("You asked the thinking partner about Design Comparison. What was unclear at first?")
  end

  it "asks where the engineer got stuck on a section rated too hard when the duck was not used" do
    chosen = pick(too_hard: %w[pattern], skipped: %w[code_review])

    expect(described_class.text(chosen)).to eq("You rated Pattern of the Month too hard. Which part did you get stuck on?")
  end

  it "asks what a skipped section would have needed when nothing else signals" do
    chosen = pick(skipped: %w[design_comparison])

    expect(described_class.text(chosen)).to eq("You skipped Design Comparison. What would you have needed to start it?")
  end

  it "falls back to the hardest part of the set when there is no signal" do
    chosen = pick

    expect(chosen.key).to eq("hardest")
    expect(described_class.text(chosen)).to eq("What was the hardest part of today's set?")
  end

  it "takes the first signalled section in the day's order within a rule" do
    expect(pick(duck_turns: %w[pattern code_review]).section).to eq("code_review")
  end

  it "ignores a signal on a section the day does not hold" do
    expect(pick(cleared: %w[architecture]).key).to eq("hardest")
  end

  it "names a kind, never a concept, in every question" do
    concepts = ConceptVocabulary::RAILS_CONCEPTS + ConceptVocabulary::JS_CONCEPTS
    texts = %w[cleared duck_turns too_hard skipped].map { |rule| described_class.text(pick(rule.to_sym => %w[code_review])) }

    expect(texts).to all(include("Code Review"))
    texts.each { |text| concepts.each { |concept| expect(text).not_to include(concept.to_s.humanize) } }
  end

  it "reads a stored key back into the question it was written to, and nothing else" do
    expect(described_class.parse("duck_turns:pattern")).to eq(described_class::Pick.new(rule: "duck_turns", section: "pattern"))
    expect(described_class.parse("hardest")).to eq(described_class::Pick.new(rule: "hardest", section: nil))
    [ nil, "", "duck_turns", "duck_turns:nope", "hardest:pattern", "other:pattern" ].each do |stored|
      expect(described_class.parse(stored)).to be_nil, "#{stored.inspect} parsed"
    end
  end
end
