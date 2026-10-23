# The one test for a Railway PR deployment; only railway.toml's [environments.pr.deploy] sets PREVIEW_APP.
module PreviewEnvironment
  VAR = "PREVIEW_APP".freeze

  def self.active?
    ENV[VAR].to_s.strip.present?
  end
end
