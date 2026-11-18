module LearnerNoteQuestions
  private

  def learner_day(exercise, response)
    sections = exercise.active_section_keys
    duck = DuckThread.for(exercise)
    LearnerDay::Signals.new(sections: sections, duck_turns: sections.index_with { |section| duck.user_turn_count(section) },
                            cleared: sections.index_with { |section| duck.cleared_count(section) },
                            too_hard: sections.select { |section| response&.self_rating_for(section) == "too_hard" },
                            answered: sections.select { |section| response&.answered?(section) })
  end

  def default_explain_section(exercise, day)
    LearnerDay.default_section(day, tags: exercise.section_concepts, recent: explain_history(exercise).recent)
  end

  def explain_box_for(exercise, day, note)
    ledger = LearnerExtraction.for(exercise)
    return saved_explain_box(note, ledger) if note&.explanation.present?

    LearnerDay.explain_box(day, tags: exercise.section_concepts, history: explain_history(exercise), closed: ledger.closed?)
  end

  def saved_explain_box(note, ledger)
    LearnerDay.saved_box(section: note.explain_section, concept: note.explain_concept, phrasing: note.explain_phrasing,
                         text: note.explanation, reply: reply_view(note, ledger), note_id: note.id, stamp: note.explanation_stamp)
  end

  def reply_view(note, ledger)
    reply = note.reply
    attempts = ledger.reply_attempts
    LearnerDay::ReplyView.new(state: note.reply_state(attempts), sound: reply&.sound, correction: reply&.correction,
                              ask: note.reply_askable?(attempts))
  end

  def explain_history(exercise) = current_user.learner_notes.explain_history(before: exercise.date)
end
