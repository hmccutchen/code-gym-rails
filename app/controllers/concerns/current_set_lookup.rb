module CurrentSetLookup
  extend ActiveSupport::Concern

  private

  def current_set = current_user.current_exercise!(carry: HeldSetLookup.enabled?)

  def render_set_not_current
    render_json_error(t("errors.set_not_current"), status: :not_found, **not_current_banner)
  end

  def not_current_banner
    return {} unless StaleSetBanner.enabled?

    { outcome: "not_current", banner: out_of_date_sentence(posted_draft_scope) }
  end

  def out_of_date_sentence(shown_scope)
    shown = shown_set(shown_scope)
    paused = current_user.paused_generation_at?
    t(StaleSetNotice.out_of_date(
      held_is_shown: shown.present? && current_user.held_exercise&.id == shown.id,
      shown_submitted: shown&.daily_response&.submitted? || false,
      paused: paused,
      missing_set: missing_set_state(manual_trigger: false)
    ))
  end

  def missing_set_state(manual_trigger:)
    MissingSetState.for(
      trial_ended: current_user.trial_ended?, provider_ready: current_user.provider_ready?,
      manual_trigger: manual_trigger, failed_today: current_user.generation_failed_today?,
      weekend: Date.current.on_weekend?, paused: current_user.paused_generation_at?
    )
  end

  def shown_set(scope)
    id = DailyExercise.set_id_from_scope(scope)
    id && current_user.daily_exercises.find_by(id: id)
  end

  def posted_draft_scope
    nested = params[:response]
    params[:draft_scope].presence || (nested[:draft_scope] if nested.is_a?(ActionController::Parameters))
  end
end
