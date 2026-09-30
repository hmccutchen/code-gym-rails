# Existing specs must keep seeing the regular experience after deployment.
# First-run examples opt in with their own later INTRODUCED_AT stub.
RSpec.configure do |config|
  config.before do
    stub_const("LearningTrack::INTRODUCED_AT", Time.utc(2100, 1, 1))
  end
end
