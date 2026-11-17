class LearnerNotesController < ApplicationController
  include LearnerNotesGate
  include LearnerNoteQuestions

  # PATCH /learner_note
  def update
    return render_json_error(t("learner_notes.note.unavailable"), status: :not_found) unless learner_notes_on?

    exercise = current_user.daily_exercises.for_date.first
    return render_json_error(t("errors.no_exercise_today"), status: :not_found) unless exercise

    pick = note_question_for(exercise, exercise.daily_response)
    outcome = LearnerNote.save_body!(exercise, params[:learner_note], question_key: pick.key,
                                                                       expected_scope: params[:draft_scope].to_s)
    render_note_outcome(outcome, pick)
  end

  private

  def render_note_outcome(outcome, pick)
    case outcome
    when LearnerNote        then render json: { status: "ok", question: NoteQuestion.text(shown_note_question(outcome, pick)) }
    when :submitted         then render_json_error(t("learner_notes.note.after_submit"), status: :unprocessable_content)
    when :stale, :deleted   then render_json_error(t("flash.responses.stale_answers"), status: :conflict)
    else raise ArgumentError, "Unhandled learner note outcome: #{outcome.inspect}"
    end
  end
end
