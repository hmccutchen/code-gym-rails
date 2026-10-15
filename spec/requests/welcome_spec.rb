require "rails_helper"

RSpec.describe "Welcome", type: :request do
  def new_account(**attrs)
    User.create!(email: "new@example.com", name: "New", **attrs)
  end

  it "requires login" do
    get "/welcome"
    expect(response).to redirect_to(login_path)
  end

  it "sends a first-run account from setup to the question" do
    login_as(new_account)
    get setup_path
    expect(response).to redirect_to("/welcome")
  end

  it "sends a first-run account with a key from the dashboard without generating" do
    user = new_account(provider: "fake", api_keys: { "fake" => "fake-test-key" })
    login_as(user)

    expect { get root_path }.not_to have_enqueued_job(GenerateDailyExercisesJob)
    expect(response).to redirect_to("/welcome")
  end

  it "shows the question, both choices, the preset and the current version without a key" do
    user = new_account
    login_as(user)
    get "/welcome"

    expect(response).to have_http_status(:ok)
    document = Nokogiri::HTML(response.body)
    expect(document.at_css("title").text).to eq("Code Gym")
    expect(document.at_css("h1").text).to eq("Before you start")
    expect(document.css("[data-track]").map { |button| button["data-track"] }).to eq(%w[junior none])
    expect(response.body).to include("Early in my career", "Experienced")
    box = document.at_css("#welcome")
    expect(JSON.parse(box["data-welcome-preset-value"])).to eq(LearningTrack.preset_levels)
    expect(box["data-welcome-skill-level-value"]).to eq("junior")
    expect(box["data-welcome-version-value"]).to eq(user.section_kind_preferences_version.to_s)
    expect(box["data-welcome-url-value"]).to eq(profile_path)
    expect(box["data-welcome-setup-url-value"]).to eq(setup_path)
  end

  it "offers starting levels for Experienced in a hidden second step" do
    login_as(new_account)
    get "/welcome"

    document = Nokogiri::HTML(response.body)
    expect(response.body).to include("Pick the level your exercises start at next.")
    expect(response.body).not_to include("regular difficulty")
    step = document.at_css('[data-welcome-target="levelStep"]')
    expect(step["hidden"]).not_to be_nil
    heading = step.at_css("h2")
    expect(heading.text).to eq("Where should your exercises start?")
    expect(heading["tabindex"]).to eq("-1")
    expect(step["aria-labelledby"]).to eq(heading["id"])
    expect(step.css("[data-level]").map { |button| button["data-level"] }).to eq(TrackGraduation::LADDER)
    expect(step.css("[data-level]").map { |button| button.children.first.text.strip }).to eq(%w[Junior Mid-level Senior])
    expect(step.at_css('[data-action="click->welcome#back"]').text.strip).to eq("Back")
    expect(document.at_css('[data-track="none"]')["data-action"]).to eq("click->welcome#showLevels")
  end

  it "offers only levels a skill level can hold" do
    expect(TrackGraduation::LADDER - User::SKILL_LEVELS).to be_empty
  end

  it "never asks a backfilled account with no exercises" do
    login_as(new_account(learning_track: "none", created_at: 1.year.ago))

    get setup_path
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("Early in my career")

    get "/welcome"
    expect(response).to redirect_to(root_path)
  end

  %w[junior none].each do |track|
    it "stops asking once the account has chosen #{track}" do
      levels = track == "junior" ? LearningTrack.preset_levels : {}
      user = new_account(learning_track: track, section_kind_levels: levels)
      expect(user.reload.learning_track).to eq(track)
      login_as(user)

      get "/welcome"
      expect(response).to redirect_to(root_path)

      get setup_path
      expect(response).to have_http_status(:ok)
    end
  end

  it "does not ask an account that has already received an exercise" do
    user = new_account
    DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current,
                          problem_set: { code_review: { question: "Find the bug" } })
    login_as(user)

    get "/welcome"
    expect(response).to redirect_to(root_path)
  end
end
