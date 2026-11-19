# Off unless HELD_SET_LOOKUP is exactly "1"; setting or unsetting it in Railway is the owner's call.
module HeldSetLookup
  ENV_KEY = "HELD_SET_LOOKUP"

  def self.enabled? = ENV[ENV_KEY] == "1"
end
