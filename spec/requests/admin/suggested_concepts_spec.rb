require "rails_helper"

RSpec.describe "Admin::SuggestedConcepts", type: :request do
  let(:admin) { create_user_with_key(email: "admin@example.com") }
  let(:member) { create_user_with_key(email: "member@example.com") }

  before { ENV["ADMIN_EMAILS"] = "admin@example.com" }
  after  { ENV.delete("ADMIN_EMAILS") }

  def delete_admin_once_the_request_is_past_sign_in
    allow(SuggestedConcept).to receive(:find).and_wrap_original do |original, *args|
      original.call(*args).tap { AccountDeletion.call(admin) }
    end
  end

  shared_examples "a review that lands after the admin's account is deleted" do |action|
    it "writes nothing and answers as signed out" do
      login_as(admin)
      concept = SuggestedConcept.record!(language: "ruby_rails", name: "circuit_breaker")
      ConceptReference.create!(language: "ruby_rails", concept: "circuit_breaker")
      delete_admin_once_the_request_is_past_sign_in

      patch public_send(:"#{action}_admin_suggested_concept_path", concept)

      expect(concept.reload.attributes.values_at("status", "reviewed_at", "reviewed_by_id")).to eq([ "pending", nil, nil ])
      expect(response).to redirect_to(login_path)
      expect(flash[:alert]).to eq(I18n.t("flash.application.login_required"))
    end
  end

  describe "a review racing the admin's own account deletion" do
    it_behaves_like "a review that lands after the admin's account is deleted", :promote
    it_behaves_like "a review that lands after the admin's account is deleted", :dismiss
  end

  describe "GET /admin/suggested_concepts" do
    it "redirects a non-admin to root with an alert" do
      login_as(member)

      get admin_suggested_concepts_path

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq("Not authorized.")
    end

    it "grants admin when the ADMIN_EMAILS entry has surrounding spaces and capitals" do
      ENV["ADMIN_EMAILS"] = "member@example.com,  Admin@Example.COM "
      login_as(admin)

      get admin_suggested_concepts_path

      expect(response).to have_http_status(:ok)
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

    it "shows when each suggestion was first and last seen as a short month and day" do
      login_as(admin)
      travel_to(Time.utc(2026, 10, 3, 12)) { SuggestedConcept.record!(language: "ruby_rails", name: "seen_twice") }
      travel_to(Time.utc(2026, 10, 21, 12)) { SuggestedConcept.record!(language: "ruby_rails", name: "seen_twice") }

      get admin_suggested_concepts_path

      row = Nokogiri::HTML(response.body).css(".suggested-table tbody tr").find { |tr| tr.text.include?("seen_twice") }
      expect(row.css("td").map { |cell| cell.text.strip }).to include("Oct 3", "Oct 21")
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

    it "counts a teammate's own write-up, since the check asks only whether the concept was ever written up" do
      login_as(admin)
      concept = SuggestedConcept.record!(language: "ruby_rails", name: "circuit_breaker")
      ConceptReference.create!(language: "ruby_rails", concept: "circuit_breaker", user: member)

      patch promote_admin_suggested_concept_path(concept)

      expect(concept.reload.status).to eq("promoted")
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
