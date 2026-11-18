class LearnerNotesController < ApplicationController
  include LearnerNotesGate
  include LearnerNoteQuestions

  # PATCH /learner_note
  def update
    return render_json_error(t("learner_notes.note.unavailable"), status: :not_found) unless learner_notes_on?

    exercise = current_user.daily_exercises.for_date.first
    return render_json_error(t("errors.no_exercise_today"), status: :not_found) unless exercise

    day = learner_day(exercise, exercise.daily_response)
    outcome = LearnerNote.save_body!(exercise, params[:learner_note], question_key: LearnerDay.note_question(day).key,
                                                                       expected_scope: params[:draft_scope].to_s)
    render_note_outcome(outcome, day)
  end

  private

  def render_note_outcome(outcome, day)
    case outcome
    when LearnerNote        then render json: { status: "ok", question: NoteQuestion.text(LearnerDay.note_question(day, stored: outcome.question_key)) }
    when :submitted         then render_json_error(t("learner_notes.note.after_submit"), status: :unprocessable_content)
    when :stale, :deleted   then render_json_error(t("flash.responses.stale_answers"), status: :conflict)
    else raise ArgumentError, "Unhandled learner note outcome: #{outcome.inspect}"
    end
  end
end
