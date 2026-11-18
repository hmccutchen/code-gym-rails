class LearnerExplanationsController < ApplicationController
  include ProviderCallLimits
  include ProviderFailureRendering
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

    day = learner_day(exercise, exercise.daily_response)
    default_section = default_explain_section(exercise, day)
    outcome = LearnerNote.save_explanation!(exercise, section: params[:section].to_s, text: text,
                                                     expected_scope: params[:draft_scope].to_s,
                                                     expected_response_id: params[:response_id].to_s)
    render_explanation_outcome(outcome, exercise, day, default_section)
  end

  # POST /learner_explanation/reply
  def reply
    return render_json_error(t("learner_notes.note.unavailable"), status: :not_found) unless learner_notes_on?

    exercise = current_user.daily_exercises.for_date.first
    note = exercise && LearnerNote.find_by(daily_exercise: exercise)
    return render_json_error(t("learner_notes.reply.no_explanation"), status: :unprocessable_content) if note&.explanation.blank?
    return render_moved(exercise) unless note.shows_explanation?(**shown_explanation)

    token = note.start_reply!(stamp: shown_explanation[:stamp])
    token.is_a?(Symbol) ? render_reply_refusal(exercise, token) : ask_for_reply(exercise, note, token)
  end

  private

  def ask_for_reply(exercise, note, token)
    reply = AiService.for(current_user).explanation_reply(
      current_user, concept: note.explain_concept.humanize, explanation: note.explanation,
                    phrasing: ExplainQuestion.text(note.explain_phrasing, note.explain_concept)
    )
    note.finish_reply!(token, reply)
    render_reply_box(exercise) { |html| render json: { status: "ok", html: html } }
  rescue ProviderError, SetupError => e
    note.release_reply!(token)
    render_reply_failure(exercise, e)
  end

  def render_reply_failure(exercise, error)
    text = provider_failure_text(error, :explanation_reply)
    Rails.logger.warn("[learner_explanation] reply failed=#{text.kind} user #{current_user.id}")
    render_reply_box(exercise) { |html| render_json_error(text.full, status: :service_unavailable, failure: text.kind, html: html) }
  end

  def render_reply_refusal(exercise, outcome)
    render_reply_box(exercise) do |html|
      next render json: { status: "ok", html: html } if outcome == :replied

      message = outcome == :busy ? "learner_notes.reply.waiting" : "learner_notes.reply.failed"
      render_json_error(t(message), status: :conflict, html: html)
    end
  end

  # The note is read again, since the Account page or Start over can delete or replace it while the call is out.
  def render_reply_box(exercise)
    note = LearnerNote.find_by(daily_exercise_id: exercise.id)
    fresh = DailyExercise.find_by(id: exercise.id)
    return render_json_error(t("learner_notes.reply.no_explanation"), status: :conflict) if note&.explanation.blank? || fresh.nil?
    return render_moved(fresh) unless note.shows_explanation?(**shown_explanation)

    yield render_to_string(partial: "shared/learner_explanation_reply", formats: [ :html ],
                           locals: { reply: reply_view(note, LearnerExtraction.for(fresh)) })
  end

  def shown_explanation = { note_id: params[:note_id].to_s, stamp: params[:explanation_stamp].to_s }

  def render_moved(exercise)
    render_json_error(t("learner_notes.reply.moved"), status: :conflict,
                                                      box: box_html(exercise, learner_day(exercise, exercise.daily_response)))
  end

  def text_refusal(text)
    if text.empty?
      t("learner_notes.explain.blank")
    elsif text.length > LearnerNote::MAX_TEXT_LENGTH
      t("learner_notes.explain.too_long", max: LearnerNote::MAX_TEXT_LENGTH)
    end
  end

  def render_explanation_outcome(outcome, exercise, day, default_section)
    if outcome.is_a?(LearnerNote)
      pick = outcome.explain_section == default_section ? "default" : "different"
      Rails.logger.info("[learner_explanation] saved pick=#{pick}")
      ExtractLearnerItemsJob.queue_early(current_user, exercise)
      return render json: { status: "ok", html: box_html(exercise, day) }
    end

    message, status = REFUSALS.fetch(outcome) { raise ArgumentError, "Unhandled explanation outcome: #{outcome.inspect}" }
    moved_on = SETTLED_REFUSALS.include?(outcome) ? { html: box_html(exercise, day) } : {}
    render_json_error(t(message), status: status, **moved_on)
  end

  def box_html(exercise, day)
    box = explain_box_for(exercise.reload, day, LearnerNote.find_by(daily_exercise: exercise))
    render_to_string(partial: "shared/learner_explanation", formats: [ :html ], locals: { box: box, draft_scope: exercise.draft_scope,
                                                                                            response_id: exercise.daily_response&.id }) if box
  end
end
