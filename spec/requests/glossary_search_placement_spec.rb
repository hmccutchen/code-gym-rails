require "rails_helper"

RSpec.describe "Glossary search boxes across every section", type: :request do
  let(:user) { create_user_with_key }
  before { login_as(user) }

  it "renders a box for code_review, pattern, and architecture on the unsubmitted dashboard" do
    DailyExercise.create!(
      user: user, date: Date.current, generated_at: Time.current,
      problem_set: {
        "code_review" => { "question" => "q", "snippet" => "s" },
        "pattern" => { "title" => "P", "question" => "q" },
        "architecture" => { "title" => "A", "question" => "q" }
      }
    )
    get root_path

    expect(response.body).to include('data-glossary-search data-field="code_review"')
    expect(response.body).to include('data-glossary-search data-field="pattern"')
    expect(response.body).to include('data-glossary-search data-field="architecture"')
  end

  it "renders a box for challenge on the unsubmitted dashboard when there is no architecture/security_review/parsons_problem section" do
    DailyExercise.create!(
      user: user, date: Date.current, generated_at: Time.current,
      problem_set: {
        "code_review" => { "question" => "q", "snippet" => "s" },
        "pattern" => { "title" => "P", "question" => "q" },
        "challenge" => { "title" => "C", "question" => "q" }
      }
    )
    get root_path

    expect(response.body).to include('data-glossary-search data-field="challenge"')
  end

  it "renders a box in every section of a submitted day, including security_review and parsons_problem" do
    exercise_a = DailyExercise.create!(
      user: user, date: 2.days.ago.to_date, generated_at: Time.current,
      problem_set: {
        "code_review" => { "question" => "q", "snippet" => "s" },
        "pattern" => { "title" => "P", "question" => "q" },
        "security_review" => { "title" => "S", "question" => "q", "snippet" => "s" }
      }
    )
    DailyResponse.create!(
      user: user, daily_exercise: exercise_a, date: exercise_a.date, submitted_at: Time.current,
      answers: { "code_review" => "a" * 20, "pattern" => "b" * 20, "security_review" => "c" * 20 },
      section_ratings: { "code_review" => "right_level", "pattern" => "right_level", "security_review" => "right_level" }
    )

    exercise_b = DailyExercise.create!(
      user: user, date: 1.day.ago.to_date, generated_at: Time.current,
      problem_set: {
        "code_review" => { "question" => "q", "snippet" => "s" },
        "pattern" => { "title" => "P", "question" => "q" },
        "parsons_problem" => { "title" => "PP", "question" => "q", "blocks" => [ "a", "b" ], "display_order" => [ 0, 1 ] }
      }
    )
    DailyResponse.create!(
      user: user, daily_exercise: exercise_b, date: exercise_b.date, submitted_at: Time.current,
      answers: { "code_review" => "a" * 20, "pattern" => "b" * 20, "parsons_problem" => "order:0,1" },
      section_ratings: { "code_review" => "right_level", "pattern" => "right_level", "parsons_problem" => "right_level" }
    )

    get history_path

    expect(response.body).to include('data-glossary-search data-field="security_review"')
    expect(response.body).to include('data-glossary-search data-field="parsons_problem"')
    expect(response.body.scan('data-glossary-search data-field="code_review"').size).to eq(2)
    expect(response.body.scan('data-glossary-search data-field="pattern"').size).to eq(2)
  end

  it "renders a box for challenge on a submitted day too" do
    exercise = DailyExercise.create!(
      user: user, date: 3.days.ago.to_date, generated_at: Time.current,
      problem_set: {
        "code_review" => { "question" => "q", "snippet" => "s" },
        "pattern" => { "title" => "P", "question" => "q" },
        "challenge" => { "title" => "C", "question" => "q" }
      }
    )
    DailyResponse.create!(
      user: user, daily_exercise: exercise, date: exercise.date, submitted_at: Time.current,
      answers: { "code_review" => "a" * 20, "pattern" => "b" * 20, "challenge" => "c" * 20 },
      section_ratings: { "code_review" => "right_level", "pattern" => "right_level", "challenge" => "right_level" }
    )

    get history_path

    expect(response.body).to include('data-glossary-search data-field="challenge"')
  end
end
