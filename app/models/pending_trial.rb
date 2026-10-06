# A trial asked for on the signed-out trial page, kept in this browser's
# session until the emailed code proves the address. The seat is taken only
# then, so nobody can spend a seat on an address they cannot read.
class PendingTrial
  KEY = :pending_trial

  def self.remember(session, email:, invite:, provider:, consented_at:)
    session[KEY] = { "email" => email, "invite_code_id" => invite.id,
                     "provider" => provider, "consented_at" => consented_at.iso8601 }
  end

  def self.forget(session) = session.delete(KEY)

  # Read once: a login takes it, whatever happens to the trial.
  def self.take(session)
    data = session.delete(KEY)
    new(data) if data.is_a?(Hash)
  end

  def initialize(data)
    @email          = data["email"].to_s
    @invite_code_id = data["invite_code_id"]
    @provider       = data["provider"].to_s
    @consented_at   = Time.iso8601(data["consented_at"].to_s)
  rescue ArgumentError
    @consented_at = nil
  end

  # :started, :has_own_key, or :rejected for a code that ran out of seats or
  # time since the form was sent.
  def start_for(user)
    return :rejected unless user.email == @email && @consented_at
    return :has_own_key if user.api_key_present?

    started = user.start_trial!(invite: InviteCode.find_by(id: @invite_code_id), provider: @provider,
                                consented_at: @consented_at)
    started ? :started : :rejected
  end
end
