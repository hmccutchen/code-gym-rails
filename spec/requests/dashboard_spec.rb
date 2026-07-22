require "rails_helper"

RSpec.describe "Dashboard feedback and review display", type: :request do
  include ActiveJob::TestHelper
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

  it "renders the rating widget at the end of the unsubmitted problem set" do
    create_exercise
    get root_path
    expect(response.body).to include('data-rating="too_easy"')
    expect(response.body).to include('data-rating="right_level"')
    expect(response.body).to include('data-rating="too_hard"')
    expect(response.body).to include("How was today's difficulty?")
  end

  it "hides the submit row and shows the nudge when the draft has no rating" do
    exercise = create_exercise
    create_response(exercise, submitted: false)

    get root_path

    expect(response.body).to match(/id="submit-row"[^>]*style="display:none"/)
    expect(response.body).to include("Rate today's difficulty to finish up.")
  end

  it "shows the submit row and marks the active button when the draft is already rated" do
    exercise = create_exercise
    create_response(exercise, submitted: false).update!(rating: :right_level)

    get root_path

    expect(response.body).not_to match(/id="submit-row"[^>]*style="display:none"/)
    expect(response.body).to include('class="rating-btn active" data-rating="right_level"')
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

  it "shows a calibration note when the self-rating was favorable but the AI rated that section beginner/developing" do
    resp = create_response(create_exercise, ai_review: sample_review)
    resp.update!(rating: :right_level)
    # sample_review's "pattern" section is rated "developing" — the disagreement case
    get root_path
    expect(response.body).to include("You rated this")
    expect(response.body).to include("just right")
  end

  it "shows the calibration note exactly once, only for the section the AI rated poorly" do
    resp = create_response(create_exercise, ai_review: sample_review)
    resp.update!(rating: :right_level)
    # code_review is "solid" and challenge is "strong" in sample_review — no note for those
    get root_path
    expect(response.body.scan("You rated this").size).to eq(1)
  end

  it "does not show the calibration note when the response was never self-rated" do
    create_response(create_exercise, ai_review: sample_review)
    get root_path
    expect(response.body).not_to include("You rated this")
  end

  it "does not show the calibration note when self-rating is too_hard, even if a section was rated poorly" do
    resp = create_response(create_exercise, ai_review: sample_review)
    resp.update!(rating: :too_hard)
    get root_path
    expect(response.body).not_to include("You rated this")
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

  describe "review button label" do
    it "names the user's provider on the get-review button" do
      user = create_user_with_key(email: "gem@example.com", name: "Gem")
      user.update!(provider: "gemini")
      login_as(user)

      exercise = DailyExercise.create!(
        user: user, date: Date.current,
        problem_set: base_problem_set,
        generated_at: Time.current
      )
      DailyResponse.create!(
        user: user, daily_exercise: exercise, date: Date.current,
        answers: { "code_review" => "An answer with plenty of substance" },
        submitted_at: Time.current
      )

      get root_path

      expect(response.body).to include("Get Gemini review →")
      expect(response.body).not_to include("Get Claude review →")
    end
  end

  describe "editable nav name" do
    it "renders the name as an editable field wired to the profile endpoint" do
      user = create_user_with_key(email: "edit@example.com", name: "Editable")
      login_as(user)

      get root_path

      # The field itself, seeded with the current name.
      expect(response.body).to include('id="nav-name-input"')
      expect(response.body).to include('value="Editable"')
      # The inline autosave script PATCHes the profile endpoint on blur. (This
      # app loads no Stimulus module JS, so the wiring is an inline script, not
      # a data-controller — see the layout comment.)
      expect(response.body).to include('fetch("' + profile_path + '", {')
      expect(response.body).to include('addEventListener("blur"')
    end
  end

  describe "brand title link" do
    it "links the brand title back to the dashboard when logged in" do
      login_as(create_user_with_key(email: "brand@example.com", name: "Brand"))

      get root_path

      expect(response.body).to match(%r{<a class="brand" href="/">⚡ Code Gym</a>})
    end
  end

  describe "on-demand generation and the weekday guard" do
    around do |example|
      # A known Monday and a known Saturday, so weekday?/weekend? are unambiguous
      # regardless of when the suite runs.
      travel_to(anchor_date) { example.run }
    end

    context "on a weekday" do
      let(:anchor_date) { Date.new(2026, 7, 13) } # Monday

      it "auto-enqueues generation and shows the generating state" do
        expect {
          get root_path
        }.to have_enqueued_job(GenerateDailyExercisesJob).with(user_id: user.id)

        expect(response.body).to include("Generating your personalized exercise set")
      end

      # Regression lock-in: the dashboard must live-update once generation
      # finishes rather than requiring a manual refresh. The placeholder's
      # wrapper id must match what GenerateDailyExercisesJob broadcasts a
      # replace against, and the page must actually subscribe to that user's
      # Turbo Stream — otherwise the job's broadcast has nothing to update.
      it "wraps the placeholder in the dashboard-content id the job broadcasts a replace to" do
        get root_path

        expect(response.body).to match(%r{<div id="dashboard-content">.*Generating your personalized exercise set.*</div>}m)
      end

      it "subscribes to the current user's Turbo Stream so the job's broadcast can reach this page" do
        get root_path

        expect(response.body).to include(Turbo::StreamsChannel.signed_stream_name(user))
      end
    end

    context "on a weekend" do
      let(:anchor_date) { Date.new(2026, 7, 18) } # Saturday

      it "does not auto-enqueue generation and shows the weekend message instead" do
        expect {
          get root_path
        }.not_to have_enqueued_job(GenerateDailyExercisesJob)

        expect(response.body).to include("No exercises are generated automatically on weekends")
        expect(response.body).to include("Generate today&#39;s set anyway")
      end
    end
  end

  describe "ConceptReference and scenario rendering" do
    let(:user) { create_user_with_key }
    before { login_as(user) }

    def exercise_with(concept:, scenario:)
      DailyExercise.create!(
        user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
        problem_set: {
          "code_review" => { "question" => "q", "snippet" => "s", "concept" => concept, "scenario" => scenario },
          "pattern"     => { "title" => "t", "why" => "w", "question" => "q", "concept" => "memoization",
                             "reference" => { "tagline" => "x", "explanation" => "y", "code_example" => "z", "senior_lens" => "w" } },
          "challenge"   => { "title" => "t", "question" => "q", "concept" => "service_objects" }
        }
      )
    end

    it "renders a concept-reference dropdown before submission when a reference is cached" do
      exercise_with(concept: "n_plus_one", scenario: "billing reconciliation")
      ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails",
                               tagline: "Avoid the loop query", explanation: "e", code_example: "c", senior_lens: "l")

      get root_path

      expect(response.body).to include("Reference — N plus one: how it works")
      expect(response.body).to include("Avoid the loop query")
    end

    it "renders the section scenario label" do
      exercise_with(concept: "n_plus_one", scenario: "billing reconciliation")

      get root_path

      expect(response.body).to include("billing reconciliation")
    end

    it "renders no dropdown for a concept with no cached reference" do
      exercise_with(concept: "n_plus_one", scenario: "billing reconciliation")

      get root_path

      expect(response.body).not_to include("Reference — N plus one: how it works")
    end

    it "renders the architecture third section with options, tradeoffs, and its concept dropdown" do
      DailyExercise.create!(
        user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
        problem_set: {
          "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one", "scenario" => "billing" },
          "pattern"     => { "title" => "t", "why" => "w", "question" => "q", "concept" => "memoization",
                             "reference" => { "tagline" => "x", "explanation" => "y", "code_example" => "z", "senior_lens" => "w" } },
          "architecture" => { "title" => "Datastore choice", "scenario" => "10x traffic", "question" => "Pick an approach",
                              "options" => [ "Shard Postgres", "Add a cache" ], "concept" => "scaling_bottlenecks",
                              "reference" => { "tagline" => "Scale reads first", "explanation" => "e",
                                               "tradeoffs" => [ "cost vs latency", "complexity vs speed" ], "senior_lens" => "l" } }
        })
      ConceptReference.create!(concept: "scaling_bottlenecks", language: "architecture",
                               tagline: "Find the bottleneck", explanation: "e", code_example: "c", senior_lens: "l")

      get root_path

      expect(response.body).to include("10x traffic")            # scenario
      expect(response.body).to include("Shard Postgres")         # an option
      expect(response.body).to include("cost vs latency")        # a tradeoff
      expect(response.body).to include("name=\"response[answers][architecture]\"")   # prose textarea
      expect(response.body).to include("Reference — Scaling bottlenecks: how it works")  # arch-bucket dropdown
      expect(response.body).not_to include("# Your implementation")  # not the challenge textarea
    end
  end
end
