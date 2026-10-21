# Off unless REVIEW_PROSE_JUDGE is exactly "1"; enabling it or changing its prompt or route must pass the gate in docs/decisions/review-prose-judge.md.
module ReviewProseJudge
  ENV_KEY = "REVIEW_PROSE_JUDGE"

  def self.enabled? = ENV[ENV_KEY] == "1"
end
