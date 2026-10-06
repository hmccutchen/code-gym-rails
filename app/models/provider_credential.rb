# Which key a user's provider call carries: their own when they stored one,
# else the house key for their provider while their trial is active. The
# house key is read here, at call time, and reaches the provider the way a
# user's key does, as a constructor argument.
#
# An account with neither is handed no key, as before trials existed; a trial
# that has ended, or whose provider has no house key, raises instead, so the
# call fails before anything is sent.
class ProviderCredential
  Credential = Data.define(:key, :house)

  def self.for(user)
    return Credential.new(key: user.api_key, house: false) if user.api_key_present?
    return Credential.new(key: nil, house: false) unless user.trial?
    raise AiService::TrialEndedError, "Trial ended for user #{user.id}" unless user.trial_active?

    Credential.new(key: HouseKeys.for(user.provider), house: true)
  end
end
