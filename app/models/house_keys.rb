# The keys trials run on, read from ENV at the moment of each call and never
# stored: HOUSE_<PROVIDER>_API_KEY, and the request count per quota day that
# HOUSE_<PROVIDER>_DAILY_GUARD allows across every trial on that key.
module HouseKeys
  def self.for(provider) = ENV[variable(provider, "API_KEY")].presence

  def self.daily_guard_for(provider)
    value = ENV[variable(provider, "DAILY_GUARD")].presence
    value && Integer(value, exception: false)
  end

  def self.variable(provider, suffix) = "HOUSE_#{provider.to_s.upcase}_#{suffix}"
end
