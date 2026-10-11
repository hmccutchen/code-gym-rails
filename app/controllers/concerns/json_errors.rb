module JsonErrors
  private

  # A string status marks the reply as the app's own, since Rails' error JSON carries a numeric one.
  def render_json_error(message, status:, outcome: "error", **details)
    render json: { status: outcome, error: message, **details }, status: status
  end
end
