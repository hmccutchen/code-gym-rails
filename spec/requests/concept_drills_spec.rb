require "rails_helper"

RSpec.describe "Concept drills", type: :request do
  let(:user) { create_user_with_key }

  before do
    user.update!(language: "ruby_rails")
    login_as(user)
  end

  def row(concept, bucket = "ruby_rails")
    user.concept_masteries.find_by(concept: concept, language: bucket)
  end

  describe "POST /learn/:bucket/:concept/drill" do
    it "starts the drill and returns to the concept page" do
      post learn_concept_drill_path(bucket: "ruby_rails", concept: "n_plus_one")

      expect(response).to redirect_to(learn_concept_path(bucket: "ruby_rails", concept: "n_plus_one"))
      expect(row("n_plus_one").drilled_at).to be_present
    end

    it "says so when the concept is already drilled" do
      ConceptDrills.start!(user, concept: "n_plus_one", bucket: "ruby_rails")

      post learn_concept_drill_path(bucket: "ruby_rails", concept: "n_plus_one")

      expect(flash[:notice]).to include("already")
    end

    it "refuses a drill past the cap and says what is already drilled" do
      ConceptDrills.start!(user, concept: "memoization", bucket: "ruby_rails")
      ConceptDrills.start_group!(user, group: "module_design", bucket: "ruby_rails")

      post learn_concept_drill_path(bucket: "ruby_rails", concept: "n_plus_one")

      expect(response).to redirect_to(learn_concept_path(bucket: "ruby_rails", concept: "n_plus_one"))
      expect(flash[:alert]).to include("Memoization").and include("Module design")
      expect(row("n_plus_one")).to be_nil
    end

    it "404s for a concept outside the bucket" do
      post learn_concept_drill_path(bucket: "ruby_rails", concept: "prototype_chain")

      expect(response).to have_http_status(:not_found)
    end

    it "404s for a bucket outside the user's slice" do
      post learn_concept_drill_path(bucket: "javascript", concept: "prototype_chain")

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE /learn/:bucket/:concept/drill" do
    it "stops the drill" do
      ConceptDrills.start!(user, concept: "n_plus_one", bucket: "ruby_rails")

      delete learn_concept_drill_path(bucket: "ruby_rails", concept: "n_plus_one")

      expect(response).to redirect_to(learn_concept_path(bucket: "ruby_rails", concept: "n_plus_one"))
      expect(row("n_plus_one").drilled_at).to be_nil
    end
  end

  describe "POST and DELETE /learn/:bucket/groups/:group/drill" do
    it "starts and stops a group drill from the index" do
      post learn_group_drill_path(bucket: "ruby_rails", group: "module_design")

      expect(response).to redirect_to(learn_path(anchor: "learn-group-ruby_rails-module_design"))
      expect(AiService::MODULE_DESIGN_CONCEPTS.map { |c| row(c).drill_group }).to all(eq("module_design"))

      delete learn_group_drill_path(bucket: "ruby_rails", group: "module_design")

      expect(user.concept_masteries.drilling).to be_empty
    end

    it "404s for a group the bucket does not hold" do
      post learn_group_drill_path(bucket: "architecture", group: "module_design")

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "the concept page" do
    it "offers the drill with a note that it clears on its own" do
      get learn_concept_path(bucket: "ruby_rails", concept: "n_plus_one")

      expect(response.body).to include("Drill this")
      expect(response.body).to include("clears on its own")
      expect(response.body).not_to include("Stop drilling")
    end

    it "shows the drill status and a stop control while drilled" do
      ConceptDrills.start!(user, concept: "n_plus_one", bucket: "ruby_rails")

      get learn_concept_path(bucket: "ruby_rails", concept: "n_plus_one")

      expect(response.body).to include("Stop drilling")
      expect(response.body).not_to include(">Drill this<")
    end

    it "names the group a member is drilled under and stops the whole group" do
      ConceptDrills.start_group!(user, group: "module_design", bucket: "ruby_rails")

      get learn_concept_path(bucket: "ruby_rails", concept: "shallow_module")

      expect(response.body).to include("as part of Module design")
      expect(response.body).to include("Stop drilling Module design")
      expect(response.body).to include(learn_group_drill_path(bucket: "ruby_rails", group: "module_design"))
      expect(response.body).not_to include(">Stop drilling<")
    end

    it "states the tradeoff before a paused concept is drilled" do
      user.concept_masteries.create!(concept: "n_plus_one", language: "ruby_rails", tier: :paused, cooldown_remaining: 2)

      get learn_concept_path(bucket: "ruby_rails", concept: "n_plus_one")

      expect(response.body).to include("Drill this")
      expect(response.body).to include("set aside")
    end

    it "still offers to rejoin a cleared member of a drilled group when the cap is full" do
      ConceptDrills.start_group!(user, group: "module_design", bucket: "ruby_rails")
      ConceptDrills.start!(user, concept: "memoization", bucket: "ruby_rails")
      row("shallow_module").clear_drill!

      get learn_concept_path(bucket: "ruby_rails", concept: "shallow_module")

      expect(response.body).to include(">Drill this<")
    end

    it "explains the cap instead of offering the drill when it is full" do
      ConceptDrills.start!(user, concept: "memoization", bucket: "ruby_rails")
      ConceptDrills.start!(user, concept: "transaction_safety", bucket: "ruby_rails")

      get learn_concept_path(bucket: "ruby_rails", concept: "n_plus_one")

      expect(response.body).not_to include(">Drill this<")
      expect(response.body).to include("Memoization").and include("Transaction safety")
    end

    it "says a drilled concept that reached the paused tier is waiting" do
      ConceptDrills.start!(user, concept: "n_plus_one", bucket: "ruby_rails")
      row("n_plus_one").update!(tier: :paused, cooldown_remaining: 2)

      get learn_concept_path(bucket: "ruby_rails", concept: "n_plus_one")

      expect(response.body).to include("Stop drilling")
      expect(response.body).to include("but waiting")
    end
  end

  describe "the index" do
    it "offers a group drill beside each named group and marks drilled entries" do
      ConceptDrills.start!(user, concept: "n_plus_one", bucket: "ruby_rails")

      get learn_path

      expect(response.body).to include(learn_group_drill_path(bucket: "ruby_rails", group: "module_design"))
      expect(response.body).to include("Drill this group")
      expect(response.body).to include('data-concept="n_plus_one"')
      expect(response.body).to include("learn-drilling")
      expect(response.body).to include("Stop drilling N plus one")
    end

    it "offers to stop a drilled group in place" do
      ConceptDrills.start_group!(user, group: "module_design", bucket: "ruby_rails")

      get learn_path

      expect(response.body).to include("Stop drilling this group")
    end

    it "offers no group drill on a bucket with a single flat group" do
      get learn_path

      expect(response.body).not_to include(learn_group_drill_path(bucket: "architecture", group: "core"))
    end
  end
end
