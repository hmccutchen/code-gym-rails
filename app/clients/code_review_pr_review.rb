module CodeReviewPrReview
  ENV_KEY = "CODE_REVIEW_PR_REVIEW".freeze

  def self.enabled? = ENV[ENV_KEY] == "1"
end
