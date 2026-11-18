module LearnerNotesHelper
  def learner_day(date) = l(date, format: :short_month_day)

  def learner_days(dates) = dates.map { |date| learner_day(date) }.to_sentence(two_words_connector: " and ", last_word_connector: " and ")

  def learner_item_origin(item)
    reference = item.first_reference
    t("accounts.learner_notes.origin", source: t("accounts.learner_notes.sources.#{reference["source"]}"),
                                       date: learner_day(Date.iso8601(reference["date"])))
  end

  def learner_item_returned(item)
    t("accounts.learner_notes.returned", closed: learner_day(item.returned_after), again: learner_day(item.came_up_dates.first))
  end

  def learner_note_question(note) = NoteQuestion.text(NoteQuestion.parse(note.question_key) || NoteQuestion.parse(NoteQuestion::NO_SIGNAL))
end
