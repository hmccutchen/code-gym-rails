# Off unless DUCK_NARROWING is exactly "1"; setting or unsetting it in Railway is the owner's call.
module DuckNarrowing
  ENV_KEY = "DUCK_NARROWING"

  def self.enabled? = ENV[ENV_KEY] == "1"
end
