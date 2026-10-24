require "rails_helper"

RSpec.describe "Setup's track control", type: :request do
  let(:user) { create_user_with_key }
  let(:keyless) { User.create!(email: "keyless@example.com", name: "Keyless", **chosen_track(true)) }
  let(:page_html) { Nokogiri::HTML(response.body) }

  def give_exercise
    DailyExercise.create!(user: user, date: Date.yesterday, generated_at: 1.day.ago,
                          problem_set: { "code_review" => { "question" => "q", "snippet" => "s" } })
  end

  it "shows the approved key guide to an account with no key and no set yet" do
    login_as(keyless)
    get setup_path

    expect(response).to have_http_status(:ok)
    guide = page_html.at_css(".key-guide")
    expect(guide).to be_present
    expect(guide.text).to include("Getting an API key", "about 20 requests a day", "A normal day here uses about 10",
                                "people at Google may read it", "works less reliably on Gemini",
                                "doesn't run on Gemini yet", "the API is prepaid", "sk-ant-", "AQ.",
                                "sk-proj-", "doesn't run on OpenAI yet")
    expect(guide.css("a").map { |link| link["href"] }).to eq([
      "https://platform.claude.com/docs/en/get-api-key",
      "https://support.claude.com/en/articles/8977456-how-do-i-pay-for-my-claude-api-usage",
      "https://ai.google.dev/gemini-api/docs/quickstart",
      "https://platform.openai.com/api-keys"
    ])
    guide.css("a").each do |link|
      expect(link["target"]).to eq("_blank")
      expect(link["rel"]).to eq("noopener")
    end
    expect(page_html.css(".phone-page .key-guide, .phone-page form").first).to eq(guide)
  end

  it "hides the guide from an account with a key of its own, and from one with a set" do
    login_as(user)
    get setup_path
    expect(page_html.at_css(".key-guide")).to be_nil

    DailyExercise.create!(user: keyless, date: Date.yesterday, generated_at: 1.day.ago,
                          problem_set: { "code_review" => { "question" => "q", "snippet" => "s" } })
    login_as(keyless)
    get setup_path
    expect(page_html.at_css(".key-guide")).to be_nil
  end

  it "names the control Track, offers principal engineer only here, and has no Leave control" do
    give_exercise
    login_as(user)
    get setup_path

    expect(page_html.at_css('label[for="skill-level"]').text).to eq("Track")
    expect(page_html.css("#skill-level option").map { |option| option["value"] }).to eq(KindDifficulty::LEVELS)
    expect(response.body).to include(ERB::Util.h(I18n.t("api_keys.edit.skill_level_hint")))
    expect(page_html.css("#learning-track, #leave-learning-track")).to be_empty
    kept = page_html.at_css('[data-profile-preferences-target="keptOwnLevel"]')
    expect(kept["role"]).to eq("status")
    expect(kept.text).to eq("")
  end

  it "says in its hint that Code Gym never suggests principal engineer" do
    expect(I18n.t("api_keys.edit.skill_level_hint")).to include("Principal engineer is set only here; Coding Gym never suggests it.")
    expect(I18n.t("welcome.note")).to include("Senior is the highest level Coding Gym suggests")
  end
end
