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
    { status: "saved", message: outcome.message, want_it_today: outcome.want_it_today, **state(outcome) }
  end

  def render_refusal(outcome)
    status = outcome.reason == :stale ? :conflict : :unprocessable_content
    render_json_error(outcome.message, status: status, outcome: outcome.reason.to_s, **state(outcome))
  end

  def state(outcome)
    { daily_kinds: outcome.daily_kinds, section_kind_preferences_version: outcome.version }
  end
end
