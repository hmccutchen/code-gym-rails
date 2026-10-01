require "rails_helper"

RSpec.describe "Setup for a learning track user", type: :request do
  let(:user) do
    User.create!(email: "track@example.com", name: "Track", learning_track: "junior",
                 section_kind_levels: LearningTrack.preset_levels)
  end

  let(:page_html) { Nokogiri::HTML(response.body) }

  it "shows the approved key guide before the first set, even without an API key" do
    login_as(user)
    get setup_path

    expect(response).to have_http_status(:ok)
    guide = page_html.at_css(".key-guide")
    expect(guide).to be_present
    expect(guide.text).to include("Getting an API key", "about 20 requests a day", "A normal day here uses about 10",
                                "people at Google may read it", "works less reliably on Gemini",
                                "doesn't run on Gemini yet", "the API is prepaid", "sk-ant-", "AQ.")
    expect(guide.css("a").map { |link| link["href"] }).to eq([
      "https://platform.claude.com/docs/en/get-api-key",
      "https://support.claude.com/en/articles/8977456-how-do-i-pay-for-my-claude-api-usage",
      "https://ai.google.dev/gemini-api/docs/quickstart"
    ])
    guide.css("a").each do |link|
      expect(link["target"]).to eq("_blank")
      expect(link["rel"]).to eq("noopener")
    end
    expect(page_html.css(".setup-wrap .key-guide, .setup-wrap form").first).to eq(guide)
  end

  it "still shows the guide after saving a key if no set exists" do
    user.update!(api_key: "fake-test-key", provider: "fake")
    login_as(user)
    get setup_path

    expect(page_html.at_css(".key-guide")).to be_present
  end

  it "hides the guide after any set exists, keeping the leave control above Exercise mix" do
    DailyExercise.create!(user: user, date: Date.yesterday, generated_at: 1.day.ago,
                          problem_set: { "code_review" => { "question" => "q", "snippet" => "s" } })
    login_as(user)
    get setup_path

    expect(page_html.at_css(".key-guide")).to be_nil
    track = page_html.at_css("#learning-track")
    expect(track).to be_present
    expect(track.text).to include("You're on the junior track", "Your current difficulty settings stay as they are.")
    expect(page_html.css("#learning-track, #exercise-mix").map { |node| node["id"] }).to eq(%w[learning-track exercise-mix])
  end

  # A nil account reaches setup only once it has an exercise; before that it
  # is a first run and is sent to the question.
  [ nil, "none" ].each do |track|
    it "shows neither control for learning_track #{track.inspect}" do
      user.update!(learning_track: track)
      DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current,
                            problem_set: { "code_review" => { "question" => "q", "snippet" => "s" } })
      login_as(user)
      get setup_path

      expect(response).to have_http_status(:ok)
      expect(page_html.css(".key-guide, #learning-track, #leave-learning-track")).to be_empty
    end
  end
end
