require "rails_helper"

RSpec.describe ApplicationHelper, type: :helper do
  describe "#page_title" do
    it "keeps the existing document title when the page supplies none" do
      expect(helper.page_title).to eq("Code Gym")
    end

    it "adds the app name to a page's title" do
      helper.content_for(:title, "Before you start")
      expect(helper.page_title).to eq("Before you start — Code Gym")
    end
  end
end
