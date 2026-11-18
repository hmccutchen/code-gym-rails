class LearnerExplanationsController < ApplicationController
  include ProviderCallLimits
  include LearnerNotesGate
  include LearnerNoteQuestions

  limit_provider_calls only: [ :reply ]

  REFUSALS = {
    explained:     [ "learner_notes.explain.already_saved", :conflict ],
    closed:        [ "learner_notes.explain.closed", :conflict ],
    not_an_option: [ "learner_notes.explain.not_an_option", :unprocessable_content ],
    not_submitted: [ "learner_notes.explain.before_submit", :unprocessable_content ],
    deleted:       [ "flash.responses.stale_answers", :conflict ],
    stale:         [ "flash.responses.stale_answers", :conflict ]
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
    outcome = LearnerNote.save_explanation!(exercise, section: params[:section].to_s, text: text,
                                                     expected_scope: params[:draft_scope].to_s)
    render_explanation_outcome(outcome, exercise, default_section)
  end

  # POST /learner_explanation/reply
  def reply
    return render_json_error(t("learner_notes.note.unavailable"), status: :not_found) unless learner_notes_on?

    exercise = current_user.daily_exercises.for_date.first
    note = exercise && LearnerNote.find_by(daily_exercise: exercise)
    return render_json_error(t("learner_notes.reply.no_explanation"), status: :unprocessable_content) if note&.explanation.blank?

    token = note.start_reply!
    token.is_a?(Symbol) ? render_reply_refusal(note, token) : ask_for_reply(note, token)
  end

  private

  def ask_for_reply(note, token)
    reply = AiService.for(current_user).explanation_reply(
      current_user, concept: note.explain_concept.humanize, explanation: note.explanation,
                    phrasing: ExplainQuestion.text(note.explain_phrasing, note.explain_concept)
    )
    note.finish_reply!(token, reply)
    render json: { status: "ok", html: reply_html(note) }
  rescue ProviderError, SetupError => e
    note.release_reply!(token)
    Rails.logger.warn("[learner_explanation] reply failed=#{ProviderFailure.classify(e)} user #{current_user.id}")
    render_json_error(t("learner_notes.reply.failed"), status: :service_unavailable, html: reply_html(note))
  end

  def render_reply_refusal(note, outcome)
    return render json: { status: "ok", html: reply_html(note) } if outcome == :replied

    message = outcome == :busy ? "learner_notes.reply.waiting" : "learner_notes.reply.failed"
    render_json_error(t(message), status: :conflict, html: reply_html(note))
  end

  def reply_html(note)
    render_to_string(partial: "shared/learner_explanation_reply", formats: [ :html ], locals: { reply: reply_view(note.reload) })
  end

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
    render_to_string(partial: "shared/learner_explanation", formats: [ :html ], locals: { box: box, draft_scope: exercise.draft_scope }) if box
  end
end
