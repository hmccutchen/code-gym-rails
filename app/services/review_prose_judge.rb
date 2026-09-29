# The deployment-wide switch for the review prose judge. Off unless
# REVIEW_PROSE_JUDGE is exactly "1": it ships off and is turned on only after
# a person reads script/compare_models.rb's review_prose output and confirms
# no rewrite changed what an entry claims.
module ReviewProseJudge
  ENV_KEY = "REVIEW_PROSE_JUDGE"

  def self.enabled? = ENV[ENV_KEY] == "1"
end
