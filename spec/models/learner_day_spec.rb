require "rails_helper"

RSpec.describe LearnerDay do
  def day(sections: %w[code_review design_comparison pattern], duck_turns: {}, cleared: {}, too_hard: [], answered: [])
    described_class::Signals.new(sections: sections, duck_turns: sections.index_with { |key| duck_turns.fetch(key, 0) },
                                 cleared: sections.index_with { |key| cleared.fetch(key, 0) }, too_hard: too_hard, answered: answered)
  end

  def history(recent: [], counts: {}) = LearnerNote::ExplainHistory.new(recent: recent, counts: counts)

  def tags = [ [ "code_review", "n_plus_one" ], [ "design_comparison", "service_objects" ], [ "pattern", nil ] ]

  describe ".passed_over" do
    it "counts a section as skipped once a later one is answered" do
      expect(described_class.passed_over(day(answered: %w[pattern]))).to eq(%w[code_review design_comparison])
      expect(described_class.passed_over(day(answered: %w[code_review]))).to eq([])
      expect(described_class.passed_over(day)).to eq([])
    end
  end

  describe ".shown_note_question" do
    it "takes a posted key that names a real question about one of the day's sections" do
      expect(described_class.shown_note_question(day, posted: "duck_turns:pattern"))
        .to eq(NoteQuestion::Pick.new(rule: "duck_turns", section: "pattern"))
      expect(described_class.shown_note_question(day, posted: NoteQuestion::NO_SIGNAL))
        .to eq(NoteQuestion::Pick.new(rule: NoteQuestion::NO_SIGNAL, section: nil))
    end

    it "refuses a made-up key, an unknown section and a section the day lacks" do
      expect(described_class.shown_note_question(day, posted: "made_up")).to be_nil
      expect(described_class.shown_note_question(day, posted: "duck_turns:nope")).to be_nil
      expect(described_class.shown_note_question(day, posted: "too_hard:security_review")).to be_nil
      expect(described_class.shown_note_question(day, posted: "")).to be_nil
    end
  end

  describe ".note_question" do
    it "follows the first signal, in NoteQuestion's order" do
      expect(described_class.note_question(day(duck_turns: { "pattern" => 2 }, too_hard: %w[code_review])))
        .to eq(NoteQuestion::Pick.new(rule: "duck_turns", section: "pattern"))
      expect(described_class.note_question(day(answered: %w[pattern])))
        .to eq(NoteQuestion::Pick.new(rule: "skipped", section: "code_review"))
      expect(described_class.note_question(day)).to eq(NoteQuestion::Pick.new(rule: NoteQuestion::NO_SIGNAL, section: nil))
    end

    it "keeps a stored pick over today's" do
      expect(described_class.note_question(day(duck_turns: { "pattern" => 2 }), stored: "too_hard:code_review"))
        .to eq(NoteQuestion::Pick.new(rule: "too_hard", section: "code_review"))
    end
  end

  describe ".default_section" do
    it "follows the duck and steps aside from a concept explained lately" do
      expect(described_class.default_section(day(duck_turns: { "design_comparison" => 1 }), tags: tags, recent: []))
        .to eq("design_comparison")
      expect(described_class.default_section(day, tags: tags, recent: %w[n_plus_one])).to eq("design_comparison")
    end

    it "is nil on a day with no usable tag" do
      expect(described_class.default_section(day, tags: [ [ "code_review", nil ] ], recent: [])).to be_nil
    end
  end

  describe ".explain_box" do
    it "is nil on a day with no usable tag" do
      expect(described_class.explain_box(day, tags: [ [ "code_review", nil ] ], history: history, closed: false)).to be_nil
    end

    it "offers each concept with its phrasing, opened on the default" do
      box = described_class.explain_box(day, tags: tags, history: history(counts: { "service_objects" => 1 }), closed: false)

      expect(box).to have_attributes(state: :open, default_section: "code_review", text: nil, reply: nil,
                                     question: ExplainQuestion.text("explain.first", "n_plus_one"))
      expect(box.choices).to eq([ described_class::ExplainChoice.new(section: "code_review", concept: "n_plus_one",
                                                                     question: ExplainQuestion.text("explain.first", "n_plus_one")),
                                  described_class::ExplainChoice.new(section: "design_comparison", concept: "service_objects",
                                                                     question: ExplainQuestion.text("explain.second", "service_objects")) ])
    end

    it "is closed once the set's ledger closed it" do
      expect(described_class.explain_box(day, tags: tags, history: history, closed: true).state).to eq(:closed)
    end
  end

  describe ".saved_box" do
    it "shows the saved explanation with its question and reply" do
      reply = described_class::ReplyView.new(state: :waiting, sound: nil, correction: nil, ask: true)

      box = described_class.saved_box(section: "code_review", concept: "n_plus_one", phrasing: "explain.second",
                                      text: "One query per row.", reply: reply)

      expect(box).to have_attributes(state: :saved, choices: [], default_section: "code_review", text: "One query per row.",
                                     reply: reply, question: ExplainQuestion.text("explain.second", "n_plus_one"))
    end
  end
end
