require "rails_helper"

RSpec.describe "Dashboard feedback and review display", type: :request do
  let(:user) { create_user_with_key }

  def base_problem_set
    {
      "code_review" => { "question" => "Find the bug", "snippet" => "def a; end" },
      "pattern" => {
        "title" => "Service Objects", "why" => "Because", "question" => "When?",
        "reference" => { "tagline" => "T", "explanation" => "E",
                         "code_example" => "code", "senior_lens" => "S" }
      },
      "challenge" => { "title" => "Build", "question" => "Implement X", "starter_code" => "" }
    }
  end

  def create_exercise(problem_set: base_problem_set)
    DailyExercise.create!(user: user, date: Date.current,
                          problem_set: problem_set, generated_at: Time.current)
  end

  def create_response(exercise, submitted: true, ai_review: nil)
    DailyResponse.create!(
      user: user, daily_exercise: exercise, date: Date.current,
      answers: { "code_review" => "a" * 20, "pattern" => "b" * 20, "challenge" => "c" * 20 },
      submitted_at: submitted ? Time.current : nil,
      ai_review: ai_review
    )
  end

  def sample_review
    {
      "code_review" => {
        "rating" => "solid", "correct" => "Good catch on the missing index",
        "missed" => "Missed the race condition", "better_questions" => "What about locks?",
        "next_step" => "Read about advisory locks", "improved_code" => "improved_code_marker"
      },
      "pattern" => { "rating" => "developing", "correct" => "Right idea", "missed" => "",
                     "better_questions" => "", "next_step" => "", "improved_code" => "" },
      "challenge" => { "rating" => "strong", "correct" => "Clean", "missed" => "",
                       "better_questions" => "", "next_step" => "", "improved_code" => "" }
    }
  end

  before { login_as(user) }

  it "shows no feedback widget before submission" do
    create_exercise
    get root_path
    expect(response.body).not_to include('class="feedback-quiet"')
    expect(response.body).not_to include('class="feedback-prominent')
  end

  it "always renders the answer form as a plain POST, even for a persisted draft" do
    exercise = create_exercise
    create_response(exercise, submitted: false)

    get root_path

    form_html = response.body[/<form[^>]*id="gym-form".*?<\/form>/m]
    expect(form_html).to be_present
    expect(form_html).to match(/method="post"/)
    expect(form_html).not_to include('name="_method"')
  end

  it "shows the quiet feedback widget after submission, before review" do
    create_response(create_exercise)
    get root_path
    expect(response.body).to include('class="feedback-quiet"')
    expect(response.body).not_to include('class="feedback-prominent')
  end

  it "shows the prominent feedback card after the review, not the quiet one" do
    create_response(create_exercise, ai_review: sample_review)
    get root_path
    expect(response.body).to include('class="feedback-prominent')
    expect(response.body).not_to include('class="feedback-quiet"')
  end

  it "renders the review with the keys review_response actually returns" do
    create_response(create_exercise, ai_review: sample_review)
    get root_path
    expect(response.body).to include("Good catch on the missing index")
    expect(response.body).to include("Missed the race condition")
    expect(response.body).to include("What about locks?")
    expect(response.body).to include("Read about advisory locks")
    expect(response.body).to include("improved_code_marker")
    expect(response.body).to include('class="review-rating">solid</span>')
  end

  it "round-trips rating and feedback text through the feedback action" do
    resp = create_response(create_exercise)
    patch feedback_response_path(resp),
          params: { response: { rating: "too_hard", feedback_text: "less SQL please" } }
    expect(resp.reload.rating).to eq("too_hard")
    expect(resp.feedback_text).to eq("less SQL please")
  end

  describe "teaching hints" do
    it "renders a locked hint before submission when a teaching_note exists" do
      ps = base_problem_set
      ps["code_review"]["teaching_note"] = "Count the queries per iteration"
      create_exercise(problem_set: ps)
      get root_path
      expect(response.body).to include("Need a nudge?")
      expect(response.body).to include("Count the queries per iteration")
      expect(response.body).to include('class="hint locked"')
    end

    it "renders the hint unlocked after submission" do
      ps = base_problem_set
      ps["pattern"]["teaching_note"] = "Think about single responsibility"
      create_response(create_exercise(problem_set: ps))
      get root_path
      expect(response.body).to include("Think about single responsibility")
      expect(response.body).not_to include('class="hint locked"')
    end

    it "renders no hint markup for exercises without teaching notes" do
      create_exercise
      get root_path
      expect(response.body).not_to include("Need a nudge?")
    end
  end

  describe "regenerate button" do
    it "shows a light confirm when there are no answers yet" do
      create_exercise
      get root_path
      expect(response.body).to include("Generate new set")
      expect(response.body).to include("Generate a new set for today?")
    end

    it "shows a strong warning once the user has draft or submitted answers" do
      create_response(create_exercise)
      get root_path
      expect(response.body).to include("erase your answers so far")
    end

    it "shows the already-regenerated message once capped, and hides the button" do
      exercise = create_exercise
      exercise.update!(regenerated_at: Time.current)
      get root_path
      expect(response.body).to include("You've already generated a new set today.")
      expect(response.body).not_to include("Generate new set")
    end
  end
end
