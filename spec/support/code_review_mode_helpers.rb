module CodeReviewModeHelpers
  def pin_code_review_mode(mode)
    allow(WeightedRoll).to receive(:pick).with(DailyPlan::CODE_REVIEW_MODE_WEIGHTS).and_return(mode)
    allow(WeightedRoll).to receive(:pick).with(DailyPlan::UNJUDGED_CODE_REVIEW_MODE_WEIGHTS).and_return(mode)
  end
end

RSpec.configure do |config|
  config.include CodeReviewModeHelpers
end
