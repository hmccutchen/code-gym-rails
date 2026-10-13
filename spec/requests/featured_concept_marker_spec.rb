require "rails_helper"

RSpec.describe "Marking the featured concept's section", type: :request do
  let(:user) { create_user_with_key }

  before { login_as(user) }

  def marker = %(<span class="featured-marker">)

  def problem_set(code_review_concept:, pattern_concept:)
    {
      "code_review" => { "question" => "Find the bug", "snippet" => "def a; end", "concept" => code_review_concept },
      "pattern" => { "title" => "Service Objects", "why" => "Because", "question" => "When?", "concept" => pattern_concept }
    }
  end

  def todays_set(submitted: false, **concepts)
    exercise = DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current, problem_set: problem_set(**concepts))
    return unless submitted

    DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current, submitted_at: Time.current,
                          answers: { "code_review" => "a" * 20, "pattern" => "b" * 20 },
                          section_ratings: { "code_review" => "right_level", "pattern" => "right_level" },
                          concept_tags: { "code_review" => concepts[:code_review_concept], "pattern" => concepts[:pattern_concept] },
                          ai_review: { "code_review" => { "rating" => "solid", "correct" => "Right" },
                                       "pattern" => { "rating" => "solid", "correct" => "Right" } })
  end

  # Each section's markup, from its opening tag to the next section's, keyed by slot number.
  def sections
    response.body.split(/(?=<(?:details|div) class="section" )/).drop(1).to_h { |chunk| [ chunk[/data-slot="(\d)"/, 1].to_i, chunk ] }
  end

  context "with a featured concept" do
    before { submit_set_showing(user, "n_plus_one", date: Date.current - 10) }

    it "marks only the matching section on the answer form, before anything is answered" do
      todays_set(code_review_concept: "n_plus_one", pattern_concept: "memoization")

      get root_path

      expect(sections[1]).to include(marker)
      expect(sections[2]).not_to include(marker)
    end

    it "marks the matching section once the day is submitted" do
      todays_set(submitted: true, code_review_concept: "memoization", pattern_concept: "n_plus_one")

      get root_path

      expect(sections[1]).not_to include(marker)
      expect(sections[2]).to include(marker)
    end

    it "marks every History entry that carries the concept, not only this week's" do
      get history_path

      expect(sections[1]).to include(marker)
    end
  end

  it "marks nothing when the user has no featured concept" do
    todays_set(code_review_concept: "n_plus_one", pattern_concept: "memoization")

    get root_path

    expect(response.body).not_to include(marker)
  end
end
