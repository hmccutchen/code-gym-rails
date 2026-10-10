# Own key first, else the house key for an active trial; an ended trial raises so the call fails before sending.
class ProviderCredential
  Credential = Data.define(:key, :house)

  def self.for(user)
    return Credential.new(key: user.api_key, house: false) if user.api_key_present?
    return Credential.new(key: nil, house: false) unless user.trial?
    raise AiService::TrialEndedError, "Trial ended for user #{user.id}" unless user.trial_active?

    Credential.new(key: HouseKeys.for(user.provider), house: true)
  end
end
