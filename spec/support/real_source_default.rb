# Without this pin every delivered-set assertion is nondeterministic; a `pick` stub with no `with` drops it.
RSpec.configure do |config|
  config.before do
    allow(WeightedRoll).to receive(:pick).and_call_original
    allow(WeightedRoll).to receive(:pick).with(RealSource::WEIGHTS).and_return(:toy)
  end
end
