# Off unless LEARNER_NOTES is exactly "1"; setting or unsetting it in Railway is the owner's call.
module LearnerNotes
  ENV_KEY = "LEARNER_NOTES"

  def self.enabled? = ENV[ENV_KEY] == "1"
end
