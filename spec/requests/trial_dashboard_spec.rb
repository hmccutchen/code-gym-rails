require "rails_helper"

# What a trial account sees on the dashboard, Setup and the provider-calling
# paths while the trial runs and once it has ended.
RSpec.describe "Trial accounts on the dashboard", type: :request do
  let(:user) { create_trial_user(provider: "fake", days: 7, cap: 12, time_zone: "America/New_York") }

  around { |example| travel_to(Time.utc(2026, 10, 7, 14)) { example.run } }

  def ended_sentence(outcome)
    "Your trial has ended, so #{outcome}. Everything you did is still here. Add your own API key in Setup to keep going."
  end

  describe "while the trial runs" do
    before { login_as(user) }

    it "shows one banner line with the days left and today's calls, and generates on demand" do
      2.times { ApiUsage.create!(user: user, purpose: "duck_thread", provider: "fake", house_key: true, tokens_in: 1, tokens_out: 1, date: Date.new(2026, 10, 7)) }

      expect { get root_path }.to have_enqueued_job(GenerateDailyExercisesJob).with(user_id: user.id)

      expect(response.body).to include("Trial: 7 days left. 2 of 12 requests used today.")
      expect(response.body).to include(%(href="#{trial_path}"))
      expect(response.body).to include("Generating your personalized exercise set")
    end

    it "shows the trial's standing on the trial page" do
      get trial_path

      expect(response.body).to include("Your trial runs until the end of October 13, 2026: 7 days left.")
      expect(response.body).to include("0 of 12 requests used today.")
      expect(response.body).to include("When the trial ends, generation and reviews stop.")
    end

    it "replaces Setup's key guide with a link to the trial page" do
      get setup_path

      expect(response.body).to include("You&#39;re on a trial", "See how your trial is going.")
      expect(response.body).not_to include("key-guide")
    end
  end

  describe "once the trial has ended" do
    # Logged in after the jump, since a session from the trial's first week
    # would have expired by then.
    before do
      travel_to(user.trial_ends_at + 1.hour)
      login_as(user)
    end

    it "shows the trial-ended panel instead of enqueuing a set, and the banner says so" do
      expect { get root_path }.not_to have_enqueued_job(GenerateDailyExercisesJob)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Your trial ended on October 13, 2026, so no set was generated today.")
      expect(response.body).to include("Everything you did is still here.", "Add your own API key in Setup to keep going.")
      expect(response.body).to include("Your trial has ended.")
      expect(response.body).not_to include("Generate today")
    end

    it "refuses an explicit generate with the trial-ended sentence" do
      post generate_path

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq(ended_sentence("nothing was generated"))
      expect(GenerateDailyExercisesJob).not_to have_been_enqueued
    end

    it "refuses the review and the thinking partner with the trial-ended sentence, keeping the answers" do
      exercise = DailyExercise.create!(user: user, date: Date.current, language: "ruby_rails", generated_at: Time.current,
                                       problem_set: { "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" } })
      daily_response = DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                                             answers: { "code_review" => "a" * 20 }, section_ratings: { "code_review" => "right_level" },
                                             submitted_at: Time.current)

      post review_response_path(daily_response)
      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq(ended_sentence("the review didn't run").sub("Everything", "Your answers are saved. Everything"))
      expect(daily_response.reload.answers["code_review"]).to eq("a" * 20)
      expect(daily_response).not_to be_reviewed

      get root_path
      expect(response.body).to include("Your trial has ended.")
      expect(response.body).not_to include("so no set was generated today")
    end

    it "shows the key guide on Setup, on or off the learning track" do
      get setup_path

      expect(response.body).to include("key-guide")
      expect(response.body).not_to include("See how your trial is going.")
    end

    it "says on the trial page when it ended" do
      get trial_path

      expect(response.body).to include("Your trial ended on October 13, 2026")
      expect(response.body).not_to include("requests used today")
    end
  end

  it "says the trial has ended without a day under the kill switch" do
    login_as(user)
    stub_env("TRIALS_DISABLED" => "1")

    get root_path

    expect(response.body).to include("Your trial has ended, so no set was generated today.")
  end

  it "sends a first-run trial account to the experience question before the trial page" do
    fresh = User.create!(email: "fresh@example.com", name: "Fresh")
    login_as(fresh)

    get trial_path

    expect(response).to redirect_to(welcome_path)
  end
end
