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
      want_it_today_link: (I18n.t("daily_kinds.picker.generate_link") if outcome.want_it_today), panels: panels, **state(outcome) }
  end

  # Every place's panel, so both cards' pickers and their version reflect the new pair without a reload.
  def panels
    exercise = current_user.daily_exercises.for_date.first
    pickers  = DailyKindSwap::Picker.for_day(current_user.reload, exercise: exercise, response: exercise&.daily_response)
    pickers.values.to_h do |picker|
      [ picker.place, render_to_string(partial: "daily_kinds/panel", formats: [ :html ], locals: { picker: picker }) ]
    end
  end

  def render_refusal(outcome)
    status = outcome.reason == :stale ? :conflict : :unprocessable_content
    render_json_error(outcome.message, status: status, outcome: outcome.reason.to_s, **state(outcome))
  end

  def state(outcome)
    { daily_kinds: outcome.daily_kinds, section_kind_preferences_version: outcome.version }
  end
end
