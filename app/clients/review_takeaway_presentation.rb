module ReviewTakeawayPresentation
  ENV_KEY = "REVIEW_TAKEAWAY"

  def self.enabled? = ENV[ENV_KEY] == "1"
end
