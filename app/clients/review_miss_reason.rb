# Off unless REVIEW_MISS_REASON is exactly "1"; setting or unsetting it in Railway is the owner's call.
module ReviewMissReason
  ENV_KEY = "REVIEW_MISS_REASON"

  def self.enabled? = ENV[ENV_KEY] == "1"
end
