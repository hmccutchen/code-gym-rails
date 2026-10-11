require "rails_helper"

RSpec.describe "disclosure chevrons" do
  let(:layout) { Rails.root.join("app/views/layouts/application.html.erb").read }

  it "draws every page's disclosure toggle with the layout's one chevron, never a text arrow" do
    Rails.root.glob("app/views/**/*.erb").each do |view|
      expect(view.read).not_to match(/content:\s*"[▶▼]/), "#{view.relative_path_from(Rails.root)} still draws a text arrow"
    end

    chevron = ViewStyles.rules(layout).find { |rule| rule.selectors.include?("details.section > summary::before") }
    expect(chevron.selectors).to include("details.review summary::before", "details.answers summary::before",
                                         "details.progress-group summary::before")
  end
end
