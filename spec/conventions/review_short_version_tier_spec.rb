require "rails_helper"

RSpec.describe "The review's short version never reads the mastery tier" do
  SHORT_VERSION_SOURCES = %w[
    app/models/review_short_version.rb
    app/views/shared/_review_short_version.html.erb
  ].freeze

  it "names ConceptMastery in neither the rules nor the partial, so the offer can't imply a tier" do
    SHORT_VERSION_SOURCES.each do |path|
      expect(Rails.root.join(path).read).not_to include("ConceptMastery"), "#{path} names ConceptMastery"
    end
  end
end
