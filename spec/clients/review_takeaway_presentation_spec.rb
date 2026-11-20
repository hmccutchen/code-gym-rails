require "rails_helper"

RSpec.describe "Review takeaway presentation" do
  it "is enabled only for the exact value 1" do
    stub_env("REVIEW_TAKEAWAY" => "1")
    expect(ReviewTakeawayPresentation).to be_enabled

    [ nil, "0", "true", " 1", "1\n" ].each do |value|
      stub_env("REVIEW_TAKEAWAY" => value)
      expect(ReviewTakeawayPresentation).not_to be_enabled
    end
  end
end
