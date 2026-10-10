require "rails_helper"

# Code is provider output, so markup inside it must reach every surface as text.
RSpec.describe "Server-highlighted code blocks", type: :request do
  PAYLOAD = %(x = "</code><script>alert('x')</script><a href="y" onclick='z'>w</a>").freeze

  let(:user) { create_user_with_key }

  before { login_as(user) }

  def page
    Nokogiri::HTML(response.body)
  end

  def expect_escaped(times:)
    expect(page.css("script").map(&:text).join).not_to include("alert('x')")
    expect(page.css("a[onclick]")).to be_empty
    lines = page.css("code.highlight .code-line").select { |line| line.text == PAYLOAD }
    expect(lines.size).to eq(times)
  end

  def create_day(third_key, third, date: Date.current)
    DailyExercise.create!(
      user: user, date: date, generated_at: Time.current, language: "ruby_rails",
      problem_set: {
        "code_review" => { "question" => "Find it", "snippet" => PAYLOAD, "current_schema" => PAYLOAD },
        "design_comparison" => { "question" => "Which?", "piece_a" => PAYLOAD, "piece_b" => PAYLOAD,
                                 "answer_key" => { "better" => "b", "deciding_fact" => "f", "principle" => "p",
                                                   "why_other_fails" => "w" } },
        third_key => third
      }
    )
  end

  {
    "challenge" => [ { "question" => "Write it", "starter_code" => PAYLOAD }, 1 ],
    "security_review" => [ { "question" => "Find it", "snippet" => PAYLOAD }, 1 ],
    "parsons_problem" => [ { "question" => "Order it", "blocks" => [ PAYLOAD, "end" ] }, 1 ]
  }.each do |third_key, (third, third_blocks)|
    it "escapes code in the code review, the schema, both comparison pieces and a #{third_key}" do
      create_day(third_key, third)

      get root_path

      expect_escaped(times: 4 + third_blocks)
    end
  end

  it "escapes the review's improved code and the pseudocode translation on the submitted page" do
    exercise = DailyExercise.create!(
      user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
      problem_set: {
        "code_review" => { "question" => "Find it", "snippet" => "def a; end" },
        "design_comparison" => { "question" => "Which?", "piece_a" => "a", "piece_b" => "b",
                                 "answer_key" => { "better" => "b", "deciding_fact" => "f", "principle" => "p",
                                                   "why_other_fails" => "w" } },
        "pseudocode_to_code" => { "question" => "Plan it", "problem_statement" => "Sum a list." }
      }
    )
    DailyResponse.create!(
      user: user, daily_exercise: exercise, date: Date.current, submitted_at: Time.current,
      answers: { "code_review" => "The method does nothing useful." },
      concept_tags: { "code_review" => "other" },
      ai_review: { "code_review" => { "rating" => "solid", "improved_code" => PAYLOAD } },
      pseudocode_rounds: { "pseudocode_to_code" => { "generated_code" => PAYLOAD } }
    )

    get root_path

    expect_escaped(times: 2)
  end

  it "escapes a concept reference's code example on its Learn page" do
    ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails", tagline: "t",
                             explanation: "e", code_example: PAYLOAD, senior_lens: "s")

    get learn_concept_path(bucket: "ruby_rails", concept: "n_plus_one")

    expect_escaped(times: 1)
  end

  it "keeps a design comparison's answer key and an ambiguity hunt's planted list out of the page" do
    DailyExercise.create!(
      user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
      problem_set: {
        "code_review" => { "question" => "Find it", "snippet" => "def a; end" },
        "design_comparison" => { "question" => "Which?", "piece_a" => "class A\nend", "piece_b" => "class B\nend",
                                 "answer_key" => { "better" => "b", "deciding_fact" => "SECRET fact",
                                                   "principle" => "SECRET principle", "why_other_fails" => "SECRET cost" } },
        "ambiguity_hunt" => { "question" => "What is unclear?", "request" => "Add a leaderboard.",
                              "planted_ambiguities" => [ "SECRET metric", "SECRET ties" ] }
      }
    )

    get root_path

    expect(page.css("code.highlight").size).to eq(3)
    expect(response.body).not_to include("SECRET")
  end
end
