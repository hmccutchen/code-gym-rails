require "rails_helper"

RSpec.describe "Admin tables on a phone", type: :system do
  let(:admin) { create_fake_provider_user(email: "admin@example.com") }

  before do
    ENV["ADMIN_EMAILS"] = admin.email
    SuggestedConcept.record!(language: "ruby_rails", name: "a_suggested_concept_with_a_long_name")
    visit_as(admin)
  end

  after { ENV.delete("ADMIN_EMAILS") }

  [ 320, 390 ].each do |width|
    it "keeps the judge solves page within a #{width}px screen, scrolling each table in its own box" do
      resize(width)
      visit admin_judge_solves_path

      expect(page).to have_css(".table-scroll .solve-counts", count: 4)
      expect(sideways_overflow).to eq(0)
    end

    it "keeps the suggested concepts page within a #{width}px screen, scrolling the table in its own box" do
      resize(width)
      visit admin_suggested_concepts_path

      expect(page).to have_css(".table-scroll .suggested-table")
      expect(sideways_overflow).to eq(0)
      expect(find(".table-scroll").evaluate_script("this.scrollWidth > this.clientWidth")).to be(true)
    end
  end
end
