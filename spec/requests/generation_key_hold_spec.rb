require "rails_helper"

RSpec.describe "The key hold on the pages and in Setup", type: :request do
  include ActiveJob::TestHelper

  let(:user) { create_user_with_key }
  let(:monday_noon) { Time.utc(2026, 7, 13, 12) }

  def hold!(account = user)
    account.update_columns(generation_account_failures: KeyHold::AFTER)
  end

  describe "PATCH /setup" do
    it "lifts the hold when a key is saved, so the schedule covers the account again" do
      hold!
      login_as(user)

      patch setup_path, params: { api_key: "sk-ant-api03-replacement" }

      expect(user.reload.generation_account_failures).to eq(0)
      expect(ScheduledGeneration.users).to include(user)
    end

    it "lifts the hold when the same key is saved again" do
      hold!
      login_as(user)

      patch setup_path, params: { api_key: user.api_key }

      expect(user.reload.generation_account_failures).to eq(0)
    end

    it "keeps the hold when only other preferences are saved" do
      hold!
      login_as(user)

      patch setup_path, params: { api_key: "", language: "javascript" }

      expect(user.reload).to have_attributes(language: "javascript", generation_account_failures: KeyHold::AFTER)
    end

    it "lifts the hold when the account switches to another stored key, so the schedule covers it again" do
      user.update!(api_keys: user.api_keys.merge("openai" => "sk-proj-Ab8RN6J5yPUsY9SwLxAS2DYq"))
      hold!
      login_as(user)

      patch setup_path, params: { api_key: "", provider: "openai" }

      expect(user.reload).to have_attributes(provider: "openai", generation_account_failures: 0)
      expect(ScheduledGeneration.users).to include(user)
    end

    it "keeps the hold when the form posts the provider already in use with another preference" do
      hold!
      login_as(user)

      patch setup_path, params: { api_key: "", provider: "anthropic", language: "javascript" }

      expect(user.reload).to have_attributes(language: "javascript", generation_account_failures: KeyHold::AFTER)
    end

    it "keeps the hold when the key is not one Setup recognizes" do
      hold!
      login_as(user)

      patch setup_path, params: { api_key: "not-a-key" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(user.reload.generation_account_failures).to eq(KeyHold::AFTER)
    end
  end

  describe "what a held account sees" do
    it "starts a generation when the dashboard opens with no set, as for any account, and shows no pause line" do
      hold!
      travel_to(monday_noon) do
        login_as(user)

        expect { get root_path }.to have_enqueued_job(GenerateDailyExercisesJob).with(user_id: user.id)
      end

      expect(response.body).to include("Generating your personalized exercise set")
      expect(Nokogiri::HTML(response.body).at_css(".automatic-pause")).to be_nil
    end

    it "shows the existing failure message with Try again, and POST /generate still starts a generation" do
      hold!
      travel_to(monday_noon) do
        user.record_generation_failure!(ProviderError::AuthenticationError.new("invalid x-api-key"))
        login_as(user)
        get root_path

        expect(response.body).to include("Claude didn&#39;t accept your API key", "Try again")
        expect { post generate_path }.to have_enqueued_job(GenerateDailyExercisesJob).with(user_id: user.id)
      end
    end

    it "leaves the Account page's button and note as they are for a running account" do
      hold!
      login_as(user)

      get account_path

      expect(response.body).to include("Automatic generation is active.", "Pause automatic generation")
      expect(response.body).not_to include("Resume automatic generation")
    end
  end
end
