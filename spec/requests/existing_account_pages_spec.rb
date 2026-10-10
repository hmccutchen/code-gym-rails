require "rails_helper"

# Rebaseline only for intended page changes: UPDATE_PAGE_SNAPSHOTS=1 bundle exec rspec <this file>
RSpec.describe "Pages for an account that predates the learning track", type: :request do
  let(:user) do
    User.create!(id: 900_001, email: "existing@example.com", name: "Existing",
                 time_zone: "UTC", created_at: Time.utc(2026, 1, 5, 12),
                 learning_track: "none").tap do |user|
      user.update!(provider: "anthropic", api_keys: { "anthropic" => "sk-ant-test-key" })
    end
  end

  let(:problem_set) do
    {
      "code_review" => { "question" => "Find the bug", "snippet" => "def a; end" },
      "pattern" => {
        "title" => "Service Objects", "why" => "Because", "question" => "When?",
        "reference" => { "tagline" => "T", "explanation" => "E", "code_example" => "code", "senior_lens" => "S" }
      },
      "challenge" => { "title" => "Build", "question" => "Implement X", "starter_code" => "" }
    }
  end

  let(:review) do
    %w[code_review pattern challenge].index_with do
      { "rating" => "solid", "correct" => "Right", "missed" => "", "better_questions" => "",
        "next_step" => "", "improved_code" => "" }
    end
  end

  around { |example| travel_to(Time.utc(2026, 9, 29, 15)) { example.run } }

  def snapshot_dir = Rails.root.join("spec/fixtures/page_snapshots")

  def exercise
    @exercise ||= DailyExercise.create!(id: 900_001, user: user, date: Date.current,
                                        problem_set: problem_set, generated_at: Time.current)
  end

  def submit_and_review
    DailyResponse.create!(id: 900_001, user: user, daily_exercise: exercise, date: Date.current,
                          answers: { "code_review" => "a" * 20, "pattern" => "b" * 20, "challenge" => "c" * 20 },
                          section_ratings: { "code_review" => "right_level", "pattern" => "right_level", "challenge" => "too_easy" },
                          submitted_at: Time.current, ai_review: review)
  end

  def expect_snapshot(name)
    expect(response).to have_http_status(:ok)
    path = snapshot_dir.join("#{name}.html")
    if ENV["UPDATE_PAGE_SNAPSHOTS"] == "1"
      FileUtils.mkdir_p(snapshot_dir)
      File.write(path, response.body)
    end

    expect(path).to exist, "No snapshot at #{path.relative_path_from(Rails.root)}. Record it with UPDATE_PAGE_SNAPSHOTS=1."
    expect(response.body).to eq(File.read(path))
  end

  before { login_as(user) }

  it "renders the unsubmitted dashboard unchanged" do
    exercise
    get root_path
    expect_snapshot("dashboard_unsubmitted")
  end

  it "renders the submitted, reviewed dashboard unchanged" do
    submit_and_review
    get root_path
    expect_snapshot("dashboard_submitted")
  end

  it "renders setup unchanged" do
    exercise
    get setup_path
    expect_snapshot("setup")
  end

  it "renders the account page unchanged" do
    get account_path
    expect_snapshot("account")
  end

  it "renders history unchanged" do
    submit_and_review
    get history_path
    expect_snapshot("history")
  end
end
