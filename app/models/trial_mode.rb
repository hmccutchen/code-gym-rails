# TRIALS_DISABLED=1 ends every trial at once without touching a row.
module TrialMode
  def self.enabled? = ENV["TRIALS_DISABLED"] != "1"

  # A provider needs both a data notice and a house key to be offered.
  def self.providers
    return [] unless enabled?

    AiProvider.all.select { |provider| provider.available? && I18n.exists?("trials.data_notice.#{provider.provider_key}") }
              .map(&:provider_key)
              .select { |key| HouseKeys.for(key).present? }
  end
end
