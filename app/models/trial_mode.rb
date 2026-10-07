# The kill switch, TRIALS_DISABLED=1, ends every trial at once, on every call
# and every page, without touching a row. It also empties the providers a new
# trial can start on.
module TrialMode
  def self.enabled? = ENV["TRIALS_DISABLED"] != "1"

  # A trial needs a data notice to consent to and a house key to run on, so
  # a provider is offered only with both; the test provider counts where it
  # is available.
  def self.providers
    return [] unless enabled?

    AiProvider.all.select { |provider| provider.available? && I18n.exists?("trials.data_notice.#{provider.provider_key}") }
              .map(&:provider_key)
              .select { |key| HouseKeys.for(key).present? }
  end
end
