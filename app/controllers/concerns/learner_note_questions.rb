module LearnerNoteQuestions
  private

  def note_question_for(exercise, response)
    sections = exercise.active_section_keys
    duck = DuckThread.for(exercise)
    NoteQuestion.pick(sections: sections,
                      cleared: sections.select { |section| duck.cleared_count(section).positive? },
                      duck_turns: sections.select { |section| duck.user_turn_count(section).positive? },
                      too_hard: sections.select { |section| response&.self_rating_for(section) == "too_hard" },
                      skipped: passed_over_sections(sections, response))
  end

  # A section counts as skipped once a later one is answered; fold state is never stored, so it cannot count.
  def passed_over_sections(sections, response)
    last_answered = response && sections.rindex { |section| response.answered?(section) }
    last_answered ? sections.first(last_answered).reject { |section| response.answered?(section) } : []
  end

  def shown_note_question(note, current_pick)
    NoteQuestion.parse(note&.question_key) || current_pick
  end
end
