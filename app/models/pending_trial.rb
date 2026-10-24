# The seat is taken only once the emailed code proves the address, so nobody spends one on an address they can't read.
class PendingTrial
  def self.dump(email:, invite:, provider:, consented_at:)
    { "email" => email, "invite_code_id" => invite.id, "provider" => provider, "consented_at" => consented_at.iso8601 }
  end

  def self.load(data)
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

  # :started, :has_own_key, or :rejected when the code ran out of seats or time since the form was sent.
  def start_for(user)
    return :rejected unless user.email == @email && @consented_at
    return :has_own_key if user.api_key_present?

    started = user.start_trial!(invite: InviteCode.find_by(id: @invite_code_id), provider: @provider,
                                consented_at: @consented_at)
    started ? :started : :rejected
  end
end
