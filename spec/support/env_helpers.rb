# ENV is read at call time by HouseKeys and TrialMode; these examples stub
# the variables they read without touching the process environment.
module EnvHelpers
  def stub_env(values)
    allow(ENV).to receive(:[]).and_call_original unless @env_stubbed
    @env_stubbed = true
    values.each { |name, value| allow(ENV).to receive(:[]).with(name).and_return(value) }
  end
end

RSpec.configure { |config| config.include EnvHelpers }
