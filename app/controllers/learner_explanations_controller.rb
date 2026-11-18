class LearnerExplanationsController < ApplicationController
  include LearnerNotesGate
  include LearnerNoteQuestions

  REFUSALS = {
    explained:     [ "learner_notes.explain.already_saved", :conflict ],
    closed:        [ "learner_notes.explain.closed", :conflict ],
    not_an_option: [ "learner_notes.explain.not_an_option", :unprocessable_content ],
    not_submitted: [ "learner_notes.explain.before_submit", :unprocessable_content ],
    deleted:       [ "flash.responses.stale_answers", :conflict ]
  }.freeze

  # A tab still showing the open box gets the box's current state for these two, since nothing can be saved now.
  SETTLED_REFUSALS = %i[explained closed].freeze

  # POST /learner_explanation
  def create
    return render_json_error(t("learner_notes.note.unavailable"), status: :not_found) unless learner_notes_on?

    exercise = current_user.daily_exercises.for_date.first
    return render_json_error(t("errors.no_exercise_today"), status: :not_found) unless exercise

    text = UserText.normalize(params[:explanation]).strip
    refusal = text_refusal(text)
    return render_json_error(refusal, status: :unprocessable_content) if refusal

    default_section = explain_box_for(exercise, exercise.daily_response, exercise.learner_note)&.default_section
    outcome = LearnerNote.save_explanation!(exercise, section: params[:section].to_s, text: text)
    render_explanation_outcome(outcome, exercise, default_section)
  end

  private

  def text_refusal(text)
    if text.empty?
      t("learner_notes.explain.blank")
    elsif text.length > LearnerNote::MAX_TEXT_LENGTH
      t("learner_notes.explain.too_long", max: LearnerNote::MAX_TEXT_LENGTH)
    end
  end

  def render_explanation_outcome(outcome, exercise, default_section)
    if outcome.is_a?(LearnerNote)
      pick = outcome.explain_section == default_section ? "default" : "different"
      Rails.logger.info("[learner_explanation] saved pick=#{pick}")
      ExtractLearnerItemsJob.queue_early(current_user, exercise)
      return render json: { status: "ok", html: box_html(exercise) }
    end

    message, status = REFUSALS.fetch(outcome) { raise ArgumentError, "Unhandled explanation outcome: #{outcome.inspect}" }
    moved_on = SETTLED_REFUSALS.include?(outcome) ? { html: box_html(exercise) } : {}
    render_json_error(t(message), status: status, **moved_on)
  end

  def box_html(exercise)
    box = explain_box_for(exercise, exercise.daily_response, LearnerNote.find_by(daily_exercise: exercise))
    render_to_string(partial: "shared/learner_explanation", formats: [ :html ], locals: { box: box }) if box
  end
end
