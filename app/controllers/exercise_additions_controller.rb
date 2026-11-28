class ExerciseAdditionsController < ApplicationController
  include CurrentSetLookup
  include ProviderCallLimits

  limit_provider_calls only: :create
  rescue_from ActiveRecord::RecordNotFound, with: :render_set_not_current

  def index
    @exercise = current_user.todays_or_held_exercise
    return render_set_not_current unless @exercise
    return stale_reply unless @exercise.draft_scope == params[:draft_scope].to_s
    return invalid_reply unless revision
    return stale_reply if revision > @exercise.manifest_revision

    state = page_state
    return stale_reply unless state

    render json: state
  end

  def create
    @exercise = shown_set_at(params[:draft_scope])
    return stale_reply unless @exercise
    current_user.carry_held_set_forward!(only: @exercise.id) if HeldSetLookup.enabled?
    @exercise.reload

    outcome = ExerciseAdditionRequest.call(user: current_user, exercise: @exercise,
      request_uuid: params[:request_uuid], kind: params[:kind], draft_scope: params[:draft_scope], revision: params[:revision],
      enqueue: ->(addition) { GenerateAdditionalExerciseJob.perform_later(addition_id: addition.id) })
    return render_set_not_current if [ :not_current, :deleted ].include?(outcome.status)
    return stale_reply if outcome.status == :stale

    @exercise.reload
    return stale_reply unless @exercise.draft_scope == params[:draft_scope].to_s

    state = page_state
    return stale_reply unless state

    status, message = case outcome.status
    when :accepted then return render json: state, status: :accepted
    when :replayed then return render json: state, status: :ok
    when :invalid then [ :unprocessable_content, "exercise_additions.refused" ]
    when :key_required then [ :unprocessable_content, "flash.application.api_key_needed" ]
    when :manifest_changed, :submitted, :busy, :unavailable then [ :conflict, "exercise_additions.refused" ]
    when :failed then [ :service_unavailable, "exercise_additions.failed" ]
    else raise ArgumentError, "Unhandled addition outcome: #{outcome.status.inspect}"
    end
    render_json_error(t(message), status: status, outcome: outcome.status.to_s, **state)
  end

  private

  def revision
    value = params[:revision].to_s
    value.to_i if value.match?(/\A\d+\z/)
  end

  def page_state
    addition = @exercise.exercise_additions.where(draft_scope: params[:draft_scope]).order(created_at: :desc, id: :desc).first
    @exercise.reload
    return unless @exercise.draft_scope == params[:draft_scope].to_s

    response = @exercise.daily_response || @exercise.build_daily_response(user: current_user, date: @exercise.date)
    { draft_scope: @exercise.draft_scope, manifest_revision: @exercise.manifest_revision,
      section_keys: @exercise.active_section_keys, answered_sections: response.answered_sections, submitted: response.submitted?,
      available_kinds: response.submitted? ? [] : ExerciseAddition.available_kinds(current_user, @exercise).map(&:key),
      operation: addition && { request_uuid: addition.request_uuid, kind: addition.kind,
        status: addition.status, expired: addition.expired? }, cards: cards(response) }
  end

  def cards(response)
    return {} if response.submitted?

    @exercise.active_section_keys.drop(revision || @exercise.manifest_revision).to_h do |key|
      [ key, render_to_string(partial: "responses/section", formats: [ :html ], locals: {
        kind: ExerciseSection.for(key), key: key, data: @exercise.problem_set.fetch(key),
        slot: @exercise.active_section_keys.index(key) + 1, exercise: @exercise, response: response, submitted: false, picker: nil
      }) ]
    end
  end

  def stale_reply
    render_json_error(t("flash.responses.stale_answers"), status: :conflict, outcome: "stale")
  end

  def invalid_reply
    render_json_error(t("exercise_additions.refused"), status: :unprocessable_content)
  end
end
