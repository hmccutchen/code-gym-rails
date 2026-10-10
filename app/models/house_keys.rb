# Read from ENV at each call and never stored.
module HouseKeys
  def self.for(provider) = ENV[variable(provider, "API_KEY")].presence

  def self.daily_guard_for(provider)
    value = ENV[variable(provider, "DAILY_GUARD")].presence
    value && Integer(value, exception: false)
  end

  def self.variable(provider, suffix) = "HOUSE_#{provider.to_s.upcase}_#{suffix}"
end
