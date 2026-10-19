class DailyKindsController < ApplicationController
  # PATCH /daily_kinds/:place
  def update
    outcome = DailyKindSwap.call(current_user, place: params[:place], kind: params[:kind],
                                               version: params[:section_kind_preferences_version])

    case outcome.status
    when :saved   then render json: saved_body(outcome)
    when :refused then render_refusal(outcome)
    else raise ArgumentError, "unhandled daily kind swap status: #{outcome.status.inspect}"
    end
  end

  private

  def saved_body(outcome)
    { status: "saved", message: outcome.message, want_it_today: outcome.want_it_today,
      want_it_today_link: (I18n.t("daily_kinds.picker.generate_link") if outcome.want_it_today), **page_state, **state(outcome) }
  end

  def page_state
    return { panels: {}, set_changed: I18n.t("daily_kinds.picker.set_changed") } if shown_set.nil?

    { panels: panels, set_changed: nil }
  end

  # The page's own generation, not today's set: past midnight it is still found, and after a regeneration it no longer is.
  def shown_set
    return @shown_set if defined?(@shown_set)

    exercise   = current_user.daily_exercises.find_by(id: params[:exercise_id])
    @shown_set = (exercise if exercise&.draft_scope == params[:draft_scope].to_s)
  end

  def panels
    pickers = DailyKindSwap::Picker.for_day(current_user.reload, exercise: shown_set, response: shown_set.daily_response)
    pickers.values.to_h do |picker|
      [ picker.place, render_to_string(partial: "daily_kinds/panel", formats: [ :html ], locals: { picker: picker }) ]
    end
  end

  def render_refusal(outcome)
    return render_json_error(outcome.message, status: :conflict, outcome: "stale", **page_state, **state(outcome)) if outcome.reason == :stale

    render_json_error(outcome.message, status: :unprocessable_content, outcome: outcome.reason.to_s, **state(outcome))
  end

  def state(outcome)
    { daily_kinds: outcome.daily_kinds, section_kind_preferences_version: outcome.version }
  end
end
