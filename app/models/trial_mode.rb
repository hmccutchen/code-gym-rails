# The kill switch: TRIALS_DISABLED=1 ends every trial at once, on every call
# and every page, without touching a row.
module TrialMode
  def self.enabled? = ENV["TRIALS_DISABLED"] != "1"
end
