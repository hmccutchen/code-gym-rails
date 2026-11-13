require "rails_helper"

RSpec.describe "A bug_hunt section on the dashboard", type: :request do
  let(:user) { create_user_with_key }

  before do
    login_as(user)
    ConceptReference.create!(user: user, concept: "memoization", language: "ruby_rails", tagline: "Remember the answer.",
                             explanation: "E", code_example: "x", senior_lens: "S")
  end

  def hunt
    { "question" => "What's wrong, why, and how would you fix it?", "purpose" => "Return whether the account may sign in.",
      "snippet" => "def allowed?\n  @allowed ||= check_account\nend", "concept" => "memoization", "pitched_at" => "junior",
      "answer_key" => { "issue" => "SENTINEL-KEY", "why_it_matters" => "w", "fix" => "f" } }
  end

  def todays_set(submitted: false, comparison_concept: "god_object")
    problem_set = { "code_review" => hunt,
                    "design_comparison" => { "question" => "Pick one", "piece_a" => "a", "piece_b" => "b", "concept" => comparison_concept } }
    exercise = DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current, problem_set: problem_set,
                                     plan_notes: { "daily_kinds" => %w[code_review design_comparison] })
    return unless submitted

    DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current, submitted_at: Time.current,
                          answers: { "code_review" => "a" * 20, "design_comparison" => "b:it" },
                          section_ratings: { "code_review" => "right_level", "design_comparison" => "right_level" },
                          concept_tags: { "code_review" => "memoization", "design_comparison" => "god_object" },
                          ai_review: { "code_review" => { "rating" => "solid", "correct" => "Right" },
                                       "design_comparison" => { "rating" => "solid", "correct" => "Right" } })
  end

  def code_review_section = response.body.split(/(?=<(?:details|div) class="section" )/).drop(1).first

  it "shows the goal line and the numbered snippet, and names the concept nowhere before submission" do
    todays_set

    get root_path

    expect(code_review_section).to include("Goal:", "Return whether the account may sign in.", "highlight numbered")
    expect(response.body).not_to include("memoization", "Memoization", "SENTINEL")
  end

  it "keeps the featured marker off the puzzle even when the featured concept matches" do
    submit_set_showing(user, "memoization", date: Date.current - 10)
    todays_set

    get root_path

    expect(code_review_section).not_to include(%(<span class="featured-marker">))
    expect(response.body).not_to include("Memoization")
  end

  describe "the featured block on Learn" do
    def featured_block = response.body[%r{<div class="featured-concept">.*?</div>}m].to_s

    it "leaves it off while today's unsubmitted puzzle is hiding the featured concept" do
      submit_set_showing(user, "memoization", date: Date.current - 10)
      todays_set

      get learn_path

      expect(featured_block).to be_empty
    end

    it "shows it again once the day is submitted" do
      submit_set_showing(user, "memoization", date: Date.current - 10)
      todays_set(submitted: true)

      get learn_path

      expect(featured_block).to include("Memoization")
    end

    it "shows it when today's set hides a different concept" do
      submit_set_showing(user, "god_object", date: Date.current - 10)
      todays_set

      get learn_path

      expect(featured_block).to include("God object")
    end

    it "leaves it off while a paused user's held set is hiding it, before the dashboard carries the set forward" do
      submit_set_showing(user, "memoization", date: Date.current - 10)
      travel_to(Date.current - 1) { todays_set }
      user.update!(paused_generation_at: 2.days.ago)

      get learn_path

      expect(featured_block).to be_empty
    end
  end

  it "shows the featured callout again once the day is submitted" do
    submit_set_showing(user, "memoization", date: Date.current - 10)
    todays_set(submitted: true)

    get root_path

    expect(response.body).to include("featured-concept", "Memoization")
  end

  it "hides the concept on another section that carries the same one" do
    todays_set(comparison_concept: "memoization")

    get root_path

    expect(response.body).not_to include("memoization", "Memoization")
  end

  it "shows the concept reference once the day is submitted" do
    todays_set(submitted: true)

    get root_path

    expect(code_review_section).to include("Goal:", "Memoization")
  end
end
