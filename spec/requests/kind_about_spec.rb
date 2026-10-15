require "rails_helper"

RSpec.describe "About each section kind", type: :request do
  let(:user) { create_user_with_key }

  def doc
    Nokogiri::HTML(response.body)
  end

  def about_keys
    doc.css("details.kind-about").map { |details| details["data-kind-about"] }
  end

  def day(date:, ratings: {}, submitted_at: Time.current)
    exercise = DailyExercise.create!(
      user: user, date: date, generated_at: Time.current, language: "ruby_rails",
      problem_set: {
        "code_review" => { "question" => "Find the bug", "snippet" => "def a; end" },
        "pattern" => { "title" => "Service Objects", "question" => "When?" }
      }
    )
    DailyResponse.create!(user: user, daily_exercise: exercise, date: date,
                          answers: ratings.keys.index_with { "an answer long enough" },
                          section_ratings: ratings, submitted_at: submitted_at)
  end

  before { login_as(user) }

  around { |example| travel_to(Time.utc(2026, 7, 15, 15)) { example.run } }

  describe "on the answer form" do
    it "explains every section to someone who has never submitted a day" do
      day(date: Date.current, submitted_at: nil)
      get root_path

      expect(about_keys).to eq(%w[code_review pattern])
      about = doc.at_css('details.kind-about[data-kind-about="code_review"]')
      expect(about["open"]).to be_nil
      expect(about.at_css("summary").text).to eq("About Code Review")
      expect(about.text).to include(SectionKindGuide.for("code_review")[:summary],
                                    SectionKindGuide.for("code_review")[:example])
    end

    it "renders beside each section summary, never inside it" do
      day(date: Date.current, submitted_at: nil)
      get root_path

      expect(doc.css("details.section > summary details")).to be_empty
      expect(doc.css("details.section > details.kind-about").size).to eq(2)
    end

    it "drops a kind once it has been answered on a submitted day" do
      day(date: Date.current - 1, ratings: { "code_review" => "right_level" })
      day(date: Date.current, submitted_at: nil)
      get root_path

      expect(about_keys).to eq(%w[pattern])
    end

    it "keeps a kind that was skipped on a submitted day" do
      day(date: Date.current - 1, ratings: { "code_review" => "right_level" })
      day(date: Date.current, submitted_at: nil)
      get root_path

      expect(about_keys).to include("pattern")
    end

    it "keeps a kind answered only in an unsubmitted draft" do
      day(date: Date.current, ratings: { "code_review" => "right_level" }, submitted_at: nil)
      get root_path

      expect(about_keys).to eq(%w[code_review pattern])
    end
  end

  it "leaves the submitted dashboard without it" do
    day(date: Date.current, ratings: { "code_review" => "right_level" })
    get root_path

    expect(response).to have_http_status(:ok)
    expect(about_keys).to be_empty
  end

  it "leaves History without it" do
    day(date: Date.current - 1, ratings: { "code_review" => "right_level" })
    get history_path

    expect(response).to have_http_status(:ok)
    expect(about_keys).to be_empty
  end

  it "explains every kind in Setup's Exercise mix, whatever has been answered" do
    day(date: Date.current - 1, ratings: { "code_review" => "right_level", "pattern" => "too_easy" })
    get setup_path

    expect(about_keys).to match_array(ExerciseSection.keys.map(&:to_s))
    expect(doc.css(".mix-row > details.kind-about").size).to eq(ExerciseSection.keys.size)
  end
end
