require "rails_helper"

# Rebaseline only for intended page changes: UPDATE_PAGE_SNAPSHOTS=1 bundle exec rspec spec/requests/existing_account_pages_spec.rb
RSpec.describe "Pages for an account that predates the learning track", type: :request do
  let(:user) do
    User.create!(id: 900_001, email: "existing@example.com", name: "Existing",
                 time_zone: "UTC", created_at: Time.utc(2026, 1, 5, 12),
                 track_chosen_at: Time.current).tap do |user|
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

  def without_nonces(body) = body.gsub(/nonce="[^"]*"/, 'nonce="NONCE"').gsub(/content="[^"]*" name="csp-nonce"/, 'content="NONCE" name="csp-nonce"').gsub(/name="csp-nonce" content="[^"]*"/, 'name="csp-nonce" content="NONCE"')

  # A Propshaft digest moves with any edit to its asset, which is not a change to the page.
  def without_asset_digests(body) = body.gsub(%r{(/assets/[^"'\s?#]+)-\h{8}(?=\.(?:js|css|png|svg|ico|webp|woff2?)\b)}, '\\1-DIGEST')

  def expect_snapshot(name)
    expect(response).to have_http_status(:ok)
    path = snapshot_dir.join("#{name}.html")
    body = without_asset_digests(without_nonces(response.body))
    if ENV["UPDATE_PAGE_SNAPSHOTS"] == "1"
      FileUtils.mkdir_p(snapshot_dir)
      File.write(path, body)
    end

    expect(path).to exist, "No snapshot at #{path.relative_path_from(Rails.root)}. Record it with UPDATE_PAGE_SNAPSHOTS=1."
    expect(body).to eq(File.read(path))
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

  it "renders the unsubmitted dashboard for a swapped pair on a two-section day" do
    user.update!(daily_section_kinds: %w[architecture design_comparison], excluded_section_kinds: %w[parsons_problem],
                 section_kind_weights: { "challenge" => 2.0 })
    DailyExercise.create!(id: 900_002, user: user, date: Date.current, generated_at: Time.current,
                          problem_set: { "architecture" => { "title" => "Queue", "question" => "Which?" },
                                         "design_comparison" => { "question" => "Pick one" } },
                          plan_notes: { "daily_kinds" => %w[architecture design_comparison], "size" => 2 })
    get root_path
    expect_snapshot("dashboard_swapped_pair")
  end

  it "renders setup unchanged" do
    exercise
    get setup_path
    expect_snapshot("setup")
  end

  it "renders the account page unchanged" do
    without_push_credentials do
      get account_path
      expect_snapshot("account")
    end
  end

  it "renders history unchanged" do
    submit_and_review
    get history_path
    expect_snapshot("history")
  end

  it "renders progress unchanged" do
    submit_set_showing(user, "n_plus_one", date: Date.current - 2, ai: "solid")
    submit_set_showing(user, "god_object", date: Date.current - 1)
    get progress_path
    expect_snapshot("progress")
  end

  it "renders learn with its featured concept, prepare box, drill and recognition guide unchanged" do
    submit_set_showing(user, "n_plus_one", date: Date.current - 1)
    ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails", tagline: "T",
                             explanation: "E", code_example: "x", senior_lens: "S")
    ConceptDrills.start!(user, concept: "n_plus_one", bucket: "ruby_rails")
    RecognitionGuide.create!(group_key: "code_smell", questions: "Q", contrast: "C", misfires: "M")
    get learn_path
    expect_snapshot("learn")
  end
end
