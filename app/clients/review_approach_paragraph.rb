# Off unless REVIEW_APPROACH_PARAGRAPH is exactly "1"; setting or unsetting it in Railway is the owner's call.
module ReviewApproachParagraph
  ENV_KEY = "REVIEW_APPROACH_PARAGRAPH"

  def self.enabled? = ENV[ENV_KEY] == "1"
end
