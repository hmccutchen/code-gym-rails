# Without this pin a delivered-set assertion would depend on the files roll once its multi weight is above 0.
RSpec.configure do |config|
  config.before do
    allow(WeightedRoll).to receive(:pick).and_call_original
    allow(WeightedRoll).to receive(:pick).with(DailyPlan::CODE_REVIEW_FILE_WEIGHTS).and_return(:single)
  end
end
