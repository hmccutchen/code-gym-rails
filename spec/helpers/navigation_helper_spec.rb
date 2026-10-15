require "rails_helper"

RSpec.describe NavigationHelper, type: :helper do
  def at(path)
    allow(helper.request).to receive(:path).and_return(path)
  end

  describe "#nav_current?" do
    it "marks Today only on the dashboard itself, not on every path under the root" do
      at("/")
      expect(helper.nav_current?("/")).to be(true)

      at("/learn")
      expect(helper.nav_current?("/")).to be(false)
    end

    it "keeps a destination marked on the pages beneath it" do
      at("/learn/ruby_rails/n_plus_one")

      expect(helper.nav_current?("/learn")).to be(true)
      expect(helper.nav_current?("/history")).to be(false)
    end

    it "does not mark a destination whose path is only a prefix of the current one's name" do
      at("/learning_things")

      expect(helper.nav_current?("/learn")).to be(false)
    end
  end

  describe "#nav_icon" do
    it "draws a decorative icon for every destination" do
      helper.nav_destinations.each do |destination|
        icon = helper.nav_icon(destination.key)

        expect(icon).to start_with("<svg").and include('aria-hidden="true"')
      end
    end
  end
end
