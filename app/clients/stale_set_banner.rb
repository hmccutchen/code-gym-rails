# Off unless STALE_SET_BANNER is exactly "1"; setting or unsetting it in Railway is the owner's call.
module StaleSetBanner
  ENV_KEY = "STALE_SET_BANNER"

  def self.enabled? = ENV[ENV_KEY] == "1"
end
