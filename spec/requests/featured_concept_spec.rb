require "rails_helper"

RSpec.describe "Weekly featured concept", type: :request do
  let(:user) { create_user_with_key }

  before { login_as(user) }

  # The label carries an apostrophe, so a raw comparison would never match and pass vacuously.
  def featured_label
    ERB::Util.html_escape(I18n.t("learn.featured.label")).to_s
  end

  def write_up(concept, language: "ruby_rails")
    ConceptReference.create!(
      concept: concept, language: language,
      tagline: "Load the rows in one query", explanation: "e", code_example: "c", senior_lens: "s"
    )
  end

  def callout = response.body[%r{<div class="featured-concept">.*?</div>}m].to_s

  def n_plus_one_path = learn_concept_path(bucket: "ruby_rails", concept: "n_plus_one")

  def todays_set(submitted: false)
    exercise = DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current,
                                     problem_set: { "code_review" => { "question" => "Find the bug", "snippet" => "def a; end" } })
    return unless submitted

    DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current, submitted_at: Time.current,
                          answers: { "code_review" => "a" * 20 }, section_ratings: { "code_review" => "right_level" },
                          ai_review: { "code_review" => { "rating" => "solid", "correct" => "Right" } })
  end

  context "on the Learn tab" do
    it "shows the user's met concept with how many sets showed it, and its tagline" do
      submit_set_showing(user, "n_plus_one", date: Date.current - 3)
      submit_set_showing(user, "n_plus_one", date: Date.current - 2)
      write_up("n_plus_one")

      get learn_path

      expect(callout).to include(n_plus_one_path, "seen in 2 of your sets", "Load the rows in one query")
    end

    it "renders no callout before the user has met a concept" do
      write_up("n_plus_one")

      get learn_path

      expect(response.body).not_to include(featured_label)
    end

    it "renders no callout while every met concept is held" do
      submit_set_showing(user, "n_plus_one", date: Date.current - 3, ai: "solid")

      get learn_path

      expect(response.body).not_to include(featured_label)
    end
  end

  context "on the dashboard" do
    before { write_up("n_plus_one") }

    it "shows the name and count, but not the tagline, before the day is submitted" do
      submit_set_showing(user, "n_plus_one", date: Date.current - 3)
      todays_set

      get root_path

      expect(callout).to include(n_plus_one_path, "seen in 1 of your sets")
      expect(callout).not_to include("Load the rows in one query")
    end

    it "shows the tagline once the day is submitted" do
      submit_set_showing(user, "n_plus_one", date: Date.current - 3)
      todays_set(submitted: true)

      get root_path

      expect(callout).to include("Load the rows in one query")
    end

    it "shows the callout on a weekend, when the page has no set" do
      travel_to Time.utc(2026, 9, 12, 16) do
        submit_set_showing(user, "n_plus_one", date: Date.current - 3)
        get root_path

        expect(callout).to include(n_plus_one_path)
      end
    end
  end

  it "shows each user the concept from their own work" do
    submit_set_showing(user, "n_plus_one", date: Date.current - 3)
    other = create_user_with_key(email: "other@example.com", name: "Other")
    submit_set_showing(other, "memoization", date: Date.current - 3)

    login_as(other)
    get learn_path

    expect(callout).to include(learn_concept_path(bucket: "ruby_rails", concept: "memoization"))
    expect(callout).not_to include(n_plus_one_path)
  end

  it "sends a concept with no write-up to the page that offers one" do
    submit_set_showing(user, "n_plus_one", date: Date.current - 3)

    get learn_path
    expect(callout).to include(n_plus_one_path)

    get n_plus_one_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Write this up")
  end
end
