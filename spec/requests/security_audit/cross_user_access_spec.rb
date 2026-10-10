require "rails_helper"

# `owner` holds the data and `intruder` tries to reach it; see docs/security-audit-2026-10-05.md.
RSpec.describe "Cross-user access", type: :request do
  let(:owner)    { create_user_with_key(email: "owner@example.com", name: "Owner") }
  let(:intruder) { create_user_with_key(email: "intruder@example.com", name: "Intruder") }

  let!(:owner_exercise) do
    DailyExercise.create!(
      user: owner, date: Date.current, generated_at: Time.current,
      problem_set: { "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" } }
    )
  end
  let!(:owner_response) do
    DailyResponse.create!(
      user: owner, daily_exercise: owner_exercise, date: Date.current,
      answers: { "code_review" => "The owner's own answer" },
      section_ratings: { "code_review" => "right_level" },
      submitted_at: Time.current
    )
  end

  before { login_as(intruder) }

  describe "POST /responses/:id/review" do
    it "404s for another user's response and leaves it unreviewed" do
      post review_response_path(owner_response)

      expect(response).to have_http_status(:not_found)
      expect(owner_response.reload.ai_review).to be_nil
    end
  end

  describe "POST /responses" do
    it "never writes into another user's response" do
      post responses_path, params: { response: { answers: { code_review: "An intruder's answer" }, submit: "1" } }, as: :json

      expect(owner_response.reload.answers).to eq("code_review" => "The owner's own answer")
      expect(intruder.daily_responses).to be_empty
    end
  end

  describe "POST /responses/pseudocode_critique" do
    it "does not reach another user's exercise" do
      expect(AiService).not_to receive(:for)

      post pseudocode_critique_responses_path, params: { pseudocode: "loop over the rows" }, as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /dashboard/status" do
    it "reports on the logged-in user's day only" do
      get dashboard_status_path

      expect(response.parsed_body).to eq("status" => "pending")
    end
  end

  describe "POST /regenerate" do
    it "leaves another user's set alone" do
      expect { post regenerate_path }.not_to have_enqueued_job(RegenerateExerciseJob)

      expect(owner_exercise.reload.regenerating_since).to be_nil
      expect(owner_exercise.regenerated_at).to be_nil
    end
  end

  describe "DELETE /account" do
    it "anonymizes only the logged-in user" do
      delete account_path

      expect(owner.reload.anonymized_at).to be_nil
      expect(owner.email).to eq("owner@example.com")
    end
  end

  describe "PATCH /account/toggle_generation" do
    it "pauses only the logged-in user" do
      patch toggle_generation_account_path, params: { paused: "1" }

      expect(owner.reload.paused_generation_at).to be_nil
    end
  end

  describe "push subscriptions" do
    let!(:owner_subscription) do
      owner.push_subscriptions.create!(endpoint: "https://fcm.googleapis.com/fcm/send/owner", p256dh_key: "p", auth_key: "a")
    end

    before do
      ENV["VAPID_PUBLIC_KEY"] = "public"
      ENV["VAPID_PRIVATE_KEY"] = "private"
      owner.update!(reminder_level: :ready_and_nudges)
    end

    after do
      ENV.delete("VAPID_PUBLIC_KEY")
      ENV.delete("VAPID_PRIVATE_KEY")
    end

    it "turning reminders off removes only the logged-in user's endpoints" do
      delete push_subscription_path

      expect(owner_subscription.reload.user).to eq(owner)
      expect(owner.reload.reminder_level).to eq("ready_and_nudges")
    end

    it "changing the nudge setting changes only the logged-in user" do
      patch push_subscription_path, params: { nudges: "0" }

      expect(owner.reload.reminder_level).to eq("ready_and_nudges")
    end
  end

  describe "drills" do
    before do
      owner.update!(language: "ruby_rails")
      intruder.update!(language: "ruby_rails")
      ConceptDrills.start!(owner, concept: "n_plus_one", bucket: "ruby_rails")
    end

    it "stopping a drill stops only the logged-in user's" do
      delete learn_concept_drill_path(bucket: "ruby_rails", concept: "n_plus_one")

      expect(owner.concept_masteries.find_by(concept: "n_plus_one", language: "ruby_rails").drilled_at).to be_present
    end

    it "starting a drill writes only the logged-in user's mastery rows" do
      expect {
        post learn_concept_drill_path(bucket: "ruby_rails", concept: "memoization")
      }.not_to change { owner.concept_masteries.count }
    end
  end

  describe "PATCH /profile" do
    it "ignores columns outside the profile allowlist" do
      patch profile_path, params: {
        user: {
          name: "Renamed",
          email: "owner@example.com",
          provider: "openai",
          api_keys: { "anthropic" => "sk-ant-planted" },
          anonymized_at: Time.current.iso8601,
          paused_generation_at: Time.current.iso8601,
          reminder_level: "ready_and_nudges",
          track_evidence_cutoffs: { "code_review" => { "level" => "junior" } },
          id: owner.id,
          user_id: owner.id
        }
      }, as: :json

      expect(response).to have_http_status(:ok)
      intruder.reload
      expect(intruder.name).to eq("Renamed")
      expect(intruder.email).to eq("intruder@example.com")
      expect(intruder.provider).to eq("anthropic")
      expect(intruder.api_keys).to eq("anthropic" => "sk-ant-test-key")
      expect(intruder.anonymized_at).to be_nil
      expect(intruder.paused_generation_at).to be_nil
      expect(intruder.reminder_level).to eq("none")
      expect(intruder.track_evidence_cutoffs).to eq({})
      expect(owner.reload.name).to eq("Owner")
    end
  end
end
