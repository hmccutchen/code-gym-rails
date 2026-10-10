# Off unless REVIEW_PROSE_JUDGE is exactly "1"; turning it on must pass CLAUDE.md's activation gate first.
module ReviewProseJudge
  ENV_KEY = "REVIEW_PROSE_JUDGE"

  def self.enabled? = ENV[ENV_KEY] == "1"
end
