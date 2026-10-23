require "rails_helper"

RSpec.describe "Welcome", type: :request do
  def new_account(**attrs)
    User.create!(email: "new@example.com", name: "New", **attrs)
  end

  it "requires login" do
    get "/welcome"
    expect(response).to redirect_to(new_user_session_path)
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

  it "offers one choice per track up to senior, with no Experienced step and no principal engineer" do
    login_as(new_account)
    get "/welcome"

    expect(response).to have_http_status(:ok)
    document = Nokogiri::HTML(response.body)
    expect(document.at_css("title").text).to eq("Coding Gym")
    expect(document.at_css("h1").text).to eq("Before you start")
    buttons = document.css("[data-level]")
    expect(buttons.map { |button| button["data-level"] }).to eq(LevelSuggestion::LADDER)
    expect(buttons.map { |button| button.children.first.text.strip }).to eq(%w[Junior Mid-level Senior])
    expect(buttons.map { |button| button["data-action"] }.uniq).to eq([ "click->welcome#choose" ])
    expect(response.body).not_to include("Experienced", "Early in my career", "Principal engineer</button>")
    expect(response.body).to include(ERB::Util.h(I18n.t("welcome.note")))
    box = document.at_css("#welcome")
    expect(box["data-welcome-url-value"]).to eq(profile_path)
    expect(box["data-welcome-setup-url-value"]).to eq(setup_path)
  end

  it "names the default daily sections and says either can be swapped from its card" do
    login_as(new_account)
    get "/welcome"

    names = DailyKinds::DEFAULT.map { |kind| I18n.t("sections.#{kind.key}.name") }.to_sentence
    expect(response.body).to include(ERB::Util.h(I18n.t("welcome.daily_sections", sections: names)))
    expect(names).to eq("Code Review and Design Comparison")
  end

  it "says what each track's exercises are like, never a job title" do
    LevelSuggestion::LADDER.each do |level|
      expect(I18n.t("welcome.hints.#{level}")).not_to match(/\b(you are|you're) (a|an) /i)
    end
  end

  it "never asks a backfilled account with no exercises" do
    login_as(new_account(track_chosen_at: 1.year.ago, created_at: 1.year.ago))

    get "/welcome"
    expect(response).to redirect_to(root_path)
  end

  it "stops asking once the account has chosen a track" do
    user = new_account
    user.choose_track("senior")
    user.save!
    login_as(user)

    get "/welcome"
    expect(response).to redirect_to(root_path)

    get setup_path
    expect(response).to have_http_status(:ok)
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
