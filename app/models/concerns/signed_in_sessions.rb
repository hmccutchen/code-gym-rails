# Design notes: docs/code-notes/app/models/concerns/signed_in_sessions.md
module SignedInSessions
  extend ActiveSupport::Concern

  class_methods do
    # Pages and the cable connection both resolve a session here, so the websocket can't outlive one the pages reject.
    def signed_in_through(session)
      user = active.find_by(id: session[:user_id])
      user if user&.session_signed_in_valid?(session[:signed_in_at])
    end

    def session_stamp(time = Time.current)
      time.utc.iso8601(6)
    end
  end

  def session_signed_in_valid?(signed_in_at)
    signed_in = Time.iso8601(signed_in_at.to_s)
    sessions_valid_after.nil? || signed_in >= sessions_valid_after
  rescue ArgumentError
    false
  end
end
