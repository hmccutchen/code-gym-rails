module LearnerNoteQuestions
  ExplainBox = Data.define(:state, :question, :choices, :default_section, :text)
  ExplainChoice = Data.define(:section, :concept, :question)

  private

  def note_question_for(exercise, response)
    sections = exercise.active_section_keys
    signals = day_signals(exercise, response)
    NoteQuestion.pick(sections: sections,
                      cleared: signals[:cleared].select { |_, count| count.positive? }.keys,
                      duck_turns: signals[:duck_turns].select { |_, count| count.positive? }.keys,
                      too_hard: signals[:too_hard],
                      skipped: passed_over_sections(sections, response))
  end

  def shown_note_question(note, current_pick)
    NoteQuestion.parse(note&.question_key) || current_pick
  end

  def explain_box_for(exercise, response, note)
    return saved_explain_box(note) if note&.explanation.present?

    options = ExplainQuestion.options(tags: exercise.section_concepts)
    return if options.empty?

    history = current_user.learner_notes.explain_history(before: exercise.date)
    choices = options.map { |option| explain_choice(option, history) }
    default = ExplainQuestion.default(options: options, recent: history.recent, **day_signals(exercise, response))
    question = choices.find { |choice| choice.section == default.section }.question
    ExplainBox.new(state: note&.extracted_at ? :closed : :open, question: question, choices: choices,
                   default_section: default.section, text: nil)
  end

  def saved_explain_box(note)
    ExplainBox.new(state: :saved, question: ExplainQuestion.text(note.explain_phrasing, note.explain_concept),
                   choices: [], default_section: note.explain_section, text: note.explanation)
  end

  def explain_choice(option, history)
    phrasing = ExplainQuestion.phrasing(history.counts.fetch(option.concept, 0))
    ExplainChoice.new(section: option.section, concept: option.concept, question: ExplainQuestion.text(phrasing, option.concept))
  end

  def day_signals(exercise, response)
    sections = exercise.active_section_keys
    duck = DuckThread.for(exercise)
    { duck_turns: sections.index_with { |section| duck.user_turn_count(section) },
      cleared: sections.index_with { |section| duck.cleared_count(section) },
      too_hard: sections.select { |section| response&.self_rating_for(section) == "too_hard" } }
  end

  # A section counts as skipped once a later one is answered; fold state is never stored, so it cannot count.
  def passed_over_sections(sections, response)
    last_answered = response && sections.rindex { |section| response.answered?(section) }
    last_answered ? sections.first(last_answered).reject { |section| response.answered?(section) } : []
  end
end
