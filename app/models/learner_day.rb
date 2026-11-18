# Design notes: docs/code-notes/app/models/learner_day.md
module LearnerDay
  Signals = Data.define(:sections, :duck_turns, :cleared, :too_hard, :answered)
  ExplainBox = Data.define(:state, :question, :choices, :default_section, :text, :reply)
  ReplyView = Data.define(:state, :sound, :correction, :ask)
  ExplainChoice = Data.define(:section, :concept, :question)

  def self.note_question(day, stored: nil)
    NoteQuestion.parse(stored) || NoteQuestion.pick(sections: day.sections, cleared: signalled(day.cleared),
                                                    duck_turns: signalled(day.duck_turns), too_hard: day.too_hard,
                                                    skipped: passed_over(day))
  end

  # Fold state is never stored, so a section counts as skipped only once a later one is answered.
  def self.passed_over(day)
    last_answered = day.sections.rindex { |section| day.answered.include?(section) }
    last_answered ? day.sections.first(last_answered) - day.answered : []
  end

  def self.default_section(day, tags:, recent:)
    options = ExplainQuestion.options(tags: tags)
    default_option(day, options, recent)&.section
  end

  def self.explain_box(day, tags:, history:, closed:)
    options = ExplainQuestion.options(tags: tags)
    return if options.empty?

    choices = options.map { |option| choice(option, history) }
    default = default_option(day, options, history.recent).section
    ExplainBox.new(state: closed ? :closed : :open, question: choices.find { |held| held.section == default }.question,
                   choices: choices, default_section: default, text: nil, reply: nil)
  end

  def self.saved_box(section:, concept:, phrasing:, text:, reply:)
    ExplainBox.new(state: :saved, question: ExplainQuestion.text(phrasing, concept), choices: [], default_section: section,
                   text: text, reply: reply)
  end

  def self.signalled(counts) = counts.select { |_, count| count.positive? }.keys

  def self.default_option(day, options, recent)
    return if options.empty?

    ExplainQuestion.default(options: options, recent: recent, duck_turns: day.duck_turns, cleared: day.cleared, too_hard: day.too_hard)
  end

  def self.choice(option, history)
    phrasing = ExplainQuestion.phrasing(history.counts.fetch(option.concept, 0))
    ExplainChoice.new(section: option.section, concept: option.concept, question: ExplainQuestion.text(phrasing, option.concept))
  end
  private_class_method :signalled, :default_option, :choice
end
