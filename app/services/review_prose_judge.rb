# The deployment-wide switch for the review prose judge. Off unless
# REVIEW_PROSE_JUDGE is exactly "1": off in code, and set only after a person
# reads script/compare_models.rb's review_prose output against the claim
# preservation bar the activation gate in CLAUDE.md states.
module ReviewProseJudge
  ENV_KEY = "REVIEW_PROSE_JUDGE"

  def self.enabled? = ENV[ENV_KEY] == "1"
end
