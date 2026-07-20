require "rails_helper"

RSpec.describe "Admin::SuggestedConcepts", type: :request do
  let(:admin) { create_user_with_key(email: "admin@example.com", name: "Admin") }
  let(:member) { create_user_with_key(email: "member@example.com", name: "Member") }

  before { ENV["ADMIN_EMAILS"] = "admin@example.com" }
  after  { ENV.delete("ADMIN_EMAILS") }

  describe "GET /admin/suggested_concepts" do
    it "redirects a non-admin to root with an alert" do
      login_as(member)

      get admin_suggested_concepts_path

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq("Not authorized.")
    end

    it "lists pending suggestions ordered by occurrences desc, for an admin" do
      login_as(admin)
      low  = SuggestedConcept.record!(language: "ruby_rails", name: "low_freq")
      SuggestedConcept.record!(language: "ruby_rails", name: "high_freq")
      SuggestedConcept.record!(language: "ruby_rails", name: "high_freq")
      high = SuggestedConcept.find_by(normalized_name: "high_freq")

      get admin_suggested_concepts_path

      expect(response.body.index(high.display_name)).to be < response.body.index(low.display_name)
    end

    it "excludes promoted and dismissed suggestions from the default listing" do
      login_as(admin)
      SuggestedConcept.record!(language: "ruby_rails", name: "promoted_one")
                      .update!(status: "promoted")
      SuggestedConcept.record!(language: "ruby_rails", name: "dismissed_one")
                       .update!(status: "dismissed")
      SuggestedConcept.record!(language: "ruby_rails", name: "still_pending")

      get admin_suggested_concepts_path

      expect(response.body).to include("still_pending")
      expect(response.body).not_to include("promoted_one")
      expect(response.body).not_to include("dismissed_one")
    end

    it "flags whether each suggestion already has a matching ConceptReference" do
      login_as(admin)
      SuggestedConcept.record!(language: "ruby_rails", name: "has_ref")
      SuggestedConcept.record!(language: "ruby_rails", name: "no_ref")
      ConceptReference.create!(language: "ruby_rails", concept: "has_ref")

      get admin_suggested_concepts_path

      rows = Nokogiri::HTML(response.body).css(".suggested-table tbody tr")
      has_ref_row = rows.find { |row| row.text.include?("has_ref") }
      no_ref_row  = rows.find { |row| row.text.include?("no_ref") }

      expect(has_ref_row.at_css(".has-reference")).to be_present
      expect(no_ref_row.at_css(".no-reference")).to be_present
    end
  end

  describe "PATCH /admin/suggested_concepts/:id/promote" do
    it "marks the suggestion promoted when a matching ConceptReference exists" do
      login_as(admin)
      concept = SuggestedConcept.record!(language: "ruby_rails", name: "circuit_breaker")
      ConceptReference.create!(language: "ruby_rails", concept: "circuit_breaker")

      patch promote_admin_suggested_concept_path(concept)

      concept.reload
      expect(concept.status).to eq("promoted")
      expect(concept.reviewed_at).to be_present
      expect(concept.reviewed_by).to eq(admin)
      expect(response).to redirect_to(admin_suggested_concepts_path)
    end

    it "refuses to promote when no matching ConceptReference exists, with no state change" do
      login_as(admin)
      concept = SuggestedConcept.record!(language: "ruby_rails", name: "circuit_breaker")

      patch promote_admin_suggested_concept_path(concept)

      concept.reload
      expect(concept.status).to eq("pending")
      expect(concept.reviewed_at).to be_nil
      expect(flash[:alert]).to eq("Add a ConceptReference for this concept first.")
    end

    it "is not accessible to a non-admin" do
      login_as(member)
      concept = SuggestedConcept.record!(language: "ruby_rails", name: "circuit_breaker")
      ConceptReference.create!(language: "ruby_rails", concept: "circuit_breaker")

      patch promote_admin_suggested_concept_path(concept)

      expect(concept.reload.status).to eq("pending")
    end

    it "returns 404 for a non-existent suggestion" do
      login_as(admin)
      bad_id = SuggestedConcept.maximum(:id).to_i + 1

      expect {
        patch promote_admin_suggested_concept_path(id: bad_id)
      }.not_to change(SuggestedConcept, :count)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH /admin/suggested_concepts/:id/dismiss" do
    it "marks the suggestion dismissed with no ConceptReference required" do
      login_as(admin)
      concept = SuggestedConcept.record!(language: "ruby_rails", name: "one_off_typo")

      patch dismiss_admin_suggested_concept_path(concept)

      concept.reload
      expect(concept.status).to eq("dismissed")
      expect(concept.reviewed_at).to be_present
      expect(concept.reviewed_by).to eq(admin)
    end

    it "is not accessible to a non-admin" do
      login_as(member)
      concept = SuggestedConcept.record!(language: "ruby_rails", name: "one_off_typo")

      patch dismiss_admin_suggested_concept_path(concept)

      expect(concept.reload.status).to eq("pending")
    end

    it "returns 404 for a non-existent suggestion" do
      login_as(admin)
      bad_id = SuggestedConcept.maximum(:id).to_i + 1

      expect {
        patch dismiss_admin_suggested_concept_path(id: bad_id)
      }.not_to change(SuggestedConcept, :count)
      expect(response).to have_http_status(:not_found)
    end
  end
end
