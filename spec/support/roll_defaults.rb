# Each pinned roll changes what DailyPlan or ingest produce, so a delivered-set assertion needs it; a `pick` stub with no `with` drops them all.
RSpec.configure do |config|
  config.before do
    allow(WeightedRoll).to receive(:pick).and_call_original
    allow(WeightedRoll).to receive(:pick).with(RealSource::WEIGHTS).and_return(:toy)
    allow(WeightedRoll).to receive(:pick).with(ExerciseSection::CodeReview::PrReview::SELECTION_WEIGHTS).and_return("ordinary")
    allow(WeightedRoll).to receive(:pick).with(DailyPlan::CODE_REVIEW_FILE_WEIGHTS).and_return(:single)
    allow(WeightedRoll).to receive(:pick).with(DailyPlan::WEEKEND_CODE_REVIEW_MODE_WEIGHTS).and_wrap_original do |original, _weights|
      original.call(DailyPlan::CODE_REVIEW_MODE_WEIGHTS)
    end
  end
  # Browser lifecycle specs keep the ordinary initial tie stable; every other candidate group still uses the planner's roll.
  config.before(:each, type: :system) do
    allow(WeightedRoll).to receive(:pick).with(DailyKinds::DEFAULT.index_with { KindPreferences::DEFAULT_MULTIPLIER })
      .and_return(DailyKinds::DEFAULT.first)
  end
end
