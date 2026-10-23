# Design notes: docs/code-notes/app/models/concerns/signed_in_sessions.md
module SignedInSessions
  extend ActiveSupport::Concern

  RECENT_SIGN_IN = 15.minutes

  class_methods do
    # Pages and the cable connection both resolve a session here, so the websocket can't outlive one the pages reject.
    def signed_in_through(user_id:, signed_in_at:)
      user = signed_in(user_id)
      user if user&.session_signed_in_valid?(signed_in_at)
    end

    def session_stamp(time = Time.current)
      time.utc.iso8601(6)
    end

    # The one reader of a stamp session_stamp wrote; nil for anything else, which every caller treats as not signed in.
    def session_time(stamp)
      Time.iso8601(stamp.to_s)
    rescue ArgumentError
      nil
    end

    def signed_in_recently?(signed_in_at)
      signed_in = session_time(signed_in_at)
      signed_in.present? && signed_in > RECENT_SIGN_IN.ago
    end
  end

  def session_signed_in_valid?(signed_in_at)
    signed_in = self.class.session_time(signed_in_at)
    signed_in.present? && (sessions_valid_after.nil? || signed_in >= sessions_valid_after)
  end
end
