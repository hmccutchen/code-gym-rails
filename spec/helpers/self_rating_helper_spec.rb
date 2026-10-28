require "rails_helper"

RSpec.describe SelfRatingHelper, type: :helper do
  describe "#self_rating_labels" do
    it "labels every self-rating in order, in the feedback form's copy" do
      expect(helper.self_rating_labels.keys).to eq(DailyResponse::SELF_RATINGS)
      expect(helper.self_rating_labels["right_level"]).to eq("just right")
    end
  end

  describe "#self_rating_label" do
    it "matches the feedback form's copy and is nil when unrated" do
      rated   = DailyResponse.new(section_ratings: { "code_review" => "right_level" })
      unrated = DailyResponse.new

      expect(helper.self_rating_label(rated, "code_review")).to eq("just right")
      expect(helper.self_rating_label(unrated, "code_review")).to be_nil
    end
  end
end
