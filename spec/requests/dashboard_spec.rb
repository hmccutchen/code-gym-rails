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

  it "renders the rating widget at the end of the unsubmitted problem set" do
    create_exercise
    get root_path
    expect(response.body).to include('data-rating-for="code_review"')
    expect(response.body).to include('data-rating-for="pattern"')
    expect(response.body).to include('data-rating-for="challenge"')
    expect(response.body).to include('data-rating="too_easy"')
    expect(response.body).to include('data-rating="right_level"')
    expect(response.body).to include('data-rating="too_hard"')
  end

  it "disables the submit button and explains why when the draft has no rating" do
    exercise = create_exercise
    create_response(exercise, submitted: false)

    get root_path

    expect(response.body).to match(/id="submit-answers"[^>]*disabled/)
    expect(response.body).to match(/id="rating-nudge"(?![^>]*hidden)/)
    expect(response.body).to include("Rate every section's difficulty to finish up.")
  end

  it "enables the submit button and marks the active rating when the draft is already rated" do
    exercise = create_exercise
    create_response(exercise, submitted: false).update!(section_ratings: {
      "code_review" => "right_level", "pattern" => "right_level", "challenge" => "right_level"
    })

    get root_path

    expect(response.body).to match(/id="submit-answers"(?![^>]*disabled)/)
    expect(response.body).to match(/id="rating-nudge"[^>]*hidden/)
    expect(response.body).to include('data-rating-for="code_review" data-rating="right_level">Just right</button>')
  end

  it "keeps the submit button visible even when it is disabled" do
    create_exercise

    get root_path

    expect(response.body).to match(/id="submit-answers"[^>]*disabled/)
    expect(response.body).not_to match(/id="submit-row"[^>]*style="display:none"/)
  end

  it "never renders a Turbo Stream subscription tag (this app loads no Turbo JS)" do
    create_exercise
    get root_path
    expect(response.body).not_to include("turbo-cable-stream-source")
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

  it "shows the day's rating as a read-only pill after submission" do
    create_response(create_exercise).update!(section_ratings: {
      "code_review" => "right_level", "pattern" => "right_level", "challenge" => "right_level"
    })
    get root_path
    expect(response.body).to include("Code review: just right")
    expect(response.body).to include("Pattern: just right")
    expect(response.body).to include("Challenge: just right")
    expect(response.body).not_to include('data-rating-for="code_review"')
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
    resp.update!(section_ratings: {
      "code_review" => "right_level", "pattern" => "right_level", "challenge" => "right_level"
    })
    # sample_review's "pattern" section is rated "developing" — the disagreement case
    get root_path
    expect(response.body).to include("You rated this")
    expect(response.body).to include("just right")
  end

  it "shows the calibration note exactly once, only for the section the AI rated poorly" do
    resp = create_response(create_exercise, ai_review: sample_review)
    resp.update!(section_ratings: {
      "code_review" => "right_level", "pattern" => "right_level", "challenge" => "right_level"
    })
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
    resp.update!(section_ratings: {
      "code_review" => "too_hard", "pattern" => "too_hard", "challenge" => "too_hard"
    })
    get root_path
    expect(response.body).not_to include("You rated this")
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

  describe "duck thread toggle" do
    it "exposes its collapsed state and the body it controls, uniquely per section" do
      create_exercise
      get root_path

      %w[code_review pattern challenge].each do |field|
        expect(response.body).to include(
          %(aria-expanded="false" aria-controls="duck-body-#{field}")
        )
        expect(response.body).to include(%(id="duck-body-#{field}"))
      end
    end

    it "renders no duck thread toggle once the set is submitted" do
      create_response(create_exercise)
      get root_path
      expect(response.body).not_to include("aria-controls=\"duck-body-")
    end
  end

  describe "glossary tooltips (auto-hover against the full curated Glossary::TERMS list)" do
    it "wraps a curated term found in the code_review question with its definition" do
      ps = base_problem_set
      ps["code_review"]["question"] = "What does this closure capture?"
      create_exercise(problem_set: ps)
      get root_path
      expect(response.body).to include(
        %(<span class="gloss-term" data-definition="#{ERB::Util.html_escape(Glossary::TERMS['closure'])}" tabindex="0" role="button" aria-label="closure: #{ERB::Util.html_escape(Glossary::TERMS['closure'])}">closure</span>)
      )
    end

    it "wraps a curated term found in an architecture option" do
      ps = base_problem_set
      ps["architecture"] = {
        "title" => "Pick a store", "question" => "Which store fits best?",
        "options" => [ "Use memoization to cache results", "Recompute every time" ]
      }
      create_exercise(problem_set: ps)
      get root_path
      expect(response.body).to include(
        %(<span class="gloss-term" data-definition="#{ERB::Util.html_escape(Glossary::TERMS['memoization'])}" tabindex="0" role="button" aria-label="memoization: #{ERB::Util.html_escape(Glossary::TERMS['memoization'])}">memoization</span>)
      )
    end

    it "leaves a term not present in the curated glossary as plain text" do
      # A bespoke problem_set rather than base_problem_set: base_problem_set's
      # pattern title "Service Objects" itself matches the curated "service
      # objects" entry, which would produce a gloss-term span unrelated to
      # what this example is asserting.
      create_exercise(problem_set: {
        "code_review" => { "question" => "Find the bug in this frobnicator widget.", "snippet" => "def a; end" },
        "pattern"     => { "title" => "Untitled Pattern", "why" => "Because", "question" => "When?" },
        "challenge"   => { "title" => "Build", "question" => "Implement X", "starter_code" => "" }
      })
      get root_path
      expect(response.body).not_to include('<span class="gloss-term"')
      expect(response.body).to include("frobnicator widget")
    end

    it "still wraps curated terms in the read-only submitted view" do
      ps = base_problem_set
      ps["pattern"]["why"] = "It avoids duck typing surprises."
      create_response(create_exercise(problem_set: ps))
      get root_path
      expect(response.body).to include(
        %(<span class="gloss-term" data-definition="#{ERB::Util.html_escape(Glossary::TERMS['duck typing'])}" tabindex="0" role="button" aria-label="duck typing: #{ERB::Util.html_escape(Glossary::TERMS['duck typing'])}">duck typing</span>)
      )
    end

    it "renders an old exercise with a populated but now-unused glossary field without error" do
      ps = base_problem_set
      ps["code_review"]["glossary"] = [ { "term" => "closure", "definition" => "stale AI-generated definition" } ]
      create_exercise(problem_set: ps)

      expect { get root_path }.not_to raise_error
      expect(response).to have_http_status(:ok)
      # The stale per-section field is ignored entirely — the curated definition wins, not the old one.
      expect(response.body).not_to include("stale AI-generated definition")
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

    it "wires the loading-form contract with the confirm message" do
      create_exercise
      get root_path
      expect(response.body).to include('data-loading-form="true"')
      expect(response.body).to include('data-loading-label="Generating…"')
      expect(response.body).to include("data-confirm-message")
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

  describe "mobile section gutter" do
    it "renders a 600px breakpoint that pulls section cards out to the screen edges" do
      create_exercise
      get root_path

      # Tied to the selector rather than matched loose, so deleting the
      # break-out declaration cannot leave this green.
      expect(response.body).to match(/@media \(max-width: 600px\) \{\s*\.section \{[^}]*margin-inline: -1\.5rem;/)
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
        expect(response.body).to include('class="spinner"')
      end

      # Regression lock-in: the dashboard must live-update once generation
      # finishes rather than requiring a manual refresh. dashboard/_generating's
      # inline script polls GET /dashboard/status and reloads on completion —
      # the placeholder just needs to keep the dashboard-content wrapper id.
      it "wraps the placeholder in the dashboard-content id" do
        get root_path

        expect(response.body).to match(%r{<div id="dashboard-content">.*Generating your personalized exercise set.*</div>}m)
      end

      it "polls the status endpoint from the generating state" do
        get root_path

        expect(response.body).to include(dashboard_status_path)
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

      it "wires the weekend generate button as a loading form" do
        get root_path
        expect(response.body).to include('data-loading-form="true"')
        expect(response.body).to include('data-loading-label="Generating…"')
      end
    end
  end

  describe "generation failure recovery" do
    around do |example|
      travel_to(Date.new(2026, 7, 13)) { example.run } # Monday
    end

    it "shows the failure message instead of the exercise when today's generation failed" do
      user.update!(last_generation_error_date: Date.current,
                   last_generation_error: "The AI provider is rate-limiting requests — try again shortly.")

      get root_path

      expect(response.body).to include("Couldn't generate today's exercises.")
      expect(response.body).to include("The AI provider is rate-limiting requests — try again shortly.")
    end

    it "does not re-enqueue a job when today's generation already failed" do
      user.update!(last_generation_error_date: Date.current, last_generation_error: "boom")

      expect {
        get root_path
      }.not_to have_enqueued_job(GenerateDailyExercisesJob)
    end

    it "shows the generating state instead of the stale failure once a retry is triggered" do
      user.update!(last_generation_error_date: Date.current, last_generation_error: "boom")

      expect {
        post generate_path
      }.to have_enqueued_job(GenerateDailyExercisesJob)

      get root_path

      expect(response.body).to include("Generating your personalized exercise set")
    end

    it "shows the exercise, not the stale failure, once generation succeeds after an earlier failure today" do
      user.update!(last_generation_error_date: Date.current, last_generation_error: "boom")
      DailyExercise.create!(user: user, date: Date.current,
                            problem_set: base_problem_set, generated_at: Time.current)

      get root_path

      expect(response.body).not_to include("Couldn't generate today's exercises.")
      expect(response.body).to include('data-rating-for="code_review"')
    end

    it "wires the failure state's Try again button to actually retrigger generation" do
      user.update!(last_generation_error_date: Date.current, last_generation_error: "boom")

      get root_path

      expect(response.body).to match(/<form[^>]*action="#{generate_path}"/)
      expect(response.body).to include(">Try again<")
      expect(response.body).to include('data-loading-form="true"')
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
      exercise_with(concept: "n_plus_one", scenario: "invoice processing workflow")
      ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails",
                               tagline: "Avoid the loop query", explanation: "e", code_example: "c", senior_lens: "l")

      get root_path

      expect(response.body).to include("Reference — N plus one: how it works")
      expect(response.body).to include("Avoid the loop query")
    end

    it "auto-expands the dropdown on a concept's first-ever exposure" do
      exercise_with(concept: "n_plus_one", scenario: "invoice processing workflow")
      ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails",
                               tagline: "Avoid the loop query", explanation: "e", code_example: "c", senior_lens: "l")

      get root_path

      expect(response.body).to match(/<details class="ref" open>\s*<summary>Reference — N plus one: how it works/)
    end

    it "keeps the dropdown collapsed on a repeat exposure to the same concept" do
      prior_exercise = DailyExercise.create!(user: user, date: Date.current - 1, language: "ruby_rails",
                                             problem_set: { "code_review" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: prior_exercise, date: Date.current - 1,
                            answers: { "code_review" => "a" * 20 }, submitted_at: Time.current,
                            concept_tags: { "code_review" => "n_plus_one" })
      exercise_with(concept: "n_plus_one", scenario: "invoice processing workflow")
      ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails",
                               tagline: "Avoid the loop query", explanation: "e", code_example: "c", senior_lens: "l")

      get root_path

      expect(response.body).to match(/<details class="ref">\s*<summary>Reference — N plus one: how it works/)
      expect(response.body).not_to include('<details class="ref" open>')
    end

    it "renders the section scenario label" do
      exercise_with(concept: "n_plus_one", scenario: "invoice processing workflow")

      get root_path

      expect(response.body).to include("invoice processing workflow")
    end

    it "renders no dropdown for a concept with no cached reference" do
      exercise_with(concept: "n_plus_one", scenario: "invoice processing workflow")

      get root_path

      expect(response.body).not_to include("Reference — N plus one: how it works")
    end

    it "renders a section's concept-reference dropdown read-only after submission" do
      exercise = exercise_with(concept: "n_plus_one", scenario: "invoice processing workflow")
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "a" * 20 }, submitted_at: Time.current)
      ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails",
                               tagline: "Avoid the loop query", explanation: "e", code_example: "c", senior_lens: "l")

      get root_path

      expect(response.body).to include("Reference — N plus one: how it works")
      expect(response.body).to include("Avoid the loop query")
      expect(response.body).not_to include('<details class="ref" open>')
    end

    it "renders a submitted architecture answer read-only" do
      exercise = DailyExercise.create!(
        user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
        problem_set: {
          "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" },
          "pattern"     => { "title" => "t", "why" => "w", "question" => "q", "concept" => "memoization" },
          "architecture" => { "title" => "Datastore", "scenario" => "10x traffic", "question" => "Pick",
                              "options" => [ "Shard", "Cache" ], "concept" => "scaling_bottlenecks",
                              "reference" => { "tagline" => "t", "explanation" => "e",
                                               "tradeoffs" => [ "a", "b" ], "senior_lens" => "l" } }
        })
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "architecture" => "I would shard because scale" }, submitted_at: Time.current)

      get root_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("I would shard because scale")
      expect(response.body).to include("10x traffic")
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

    it "auto-expands the architecture section's dropdown on first exposure, but not once submitted" do
      exercise = DailyExercise.create!(
        user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
        problem_set: {
          "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one", "scenario" => "billing" },
          "pattern"     => { "title" => "t", "why" => "w", "question" => "q", "concept" => "memoization",
                             "reference" => { "tagline" => "x", "explanation" => "y", "code_example" => "z", "senior_lens" => "w" } },
          "architecture" => { "title" => "Datastore choice", "scenario" => "10x traffic", "question" => "Pick an approach",
                              "options" => [ "Shard Postgres", "Add a cache" ], "concept" => "scaling_bottlenecks" }
        })
      ConceptReference.create!(concept: "scaling_bottlenecks", language: "architecture",
                               tagline: "Find the bottleneck", explanation: "e", code_example: "c", senior_lens: "l")

      get root_path
      expect(response.body).to match(/<details class="ref" open>\s*<summary>Reference — Scaling bottlenecks: how it works/)

      # Deliberately omit concept_tags here: exposure count for "scaling_bottlenecks"
      # stays at 0, so first_exposure? would still be true if evaluated. Any
      # remaining collapse must come from the view's `!submitted` guard alone.
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "architecture" => "a" * 20 }, submitted_at: Time.current)

      get root_path
      expect(response.body).to match(/<details class="ref">\s*<summary>Reference — Scaling bottlenecks: how it works/)
      expect(response.body).not_to include('<details class="ref" open>')
    end
  end

  it "marks the unsubmitted form's code_review snippet for syntax highlighting" do
    exercise = create_exercise
    create_response(exercise, submitted: false)

    get root_path

    expect(response.body).to include('data-hljs="ruby"')
  end

  describe "parsons_problem third section" do
    it "renders the reorder list and a hidden answer field when today's third section is parsons_problem" do
      create_exercise(problem_set: {
        "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" },
        "pattern"     => { "title" => "P", "question" => "q", "why" => "w", "concept" => "n_plus_one" },
        "parsons_problem" => {
          "title" => "Sort names", "question" => "Arrange these blocks",
          "blocks" => [ "def sorted(names)", "  names.sort", "end" ],
          "display_order" => [ 2, 0, 1 ], "concept" => "n_plus_one"
        }
      })
      get root_path

      expect(response.body).to include("Parsons Problem: Sort names")
      expect(response.body).to include('data-field="parsons_problem"')
      expect(response.body).to include("data-parsons-blocks")
      expect(response.body.index('data-block-id="2"')).to be < response.body.index('data-block-id="0"')
    end

    it "falls back to the stored order when display_order is missing, rather than rendering nothing" do
      create_exercise(problem_set: {
        "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" },
        "pattern"     => { "title" => "P", "question" => "q", "why" => "w", "concept" => "n_plus_one" },
        "parsons_problem" => {
          "title" => "Sort names", "question" => "Arrange these blocks",
          "blocks" => [ "def sorted(names)", "  names.sort", "end" ], "concept" => "n_plus_one"
        }
      })
      get root_path

      expect(response.body).to include('data-block-id="0"')
      expect(response.body).to include('data-block-id="1"')
      expect(response.body).to include('data-block-id="2"')
    end

    it "renders every block once when a tampered answer order was saved" do
      create_exercise(problem_set: {
        "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" },
        "pattern"     => { "title" => "P", "question" => "q", "why" => "w", "concept" => "n_plus_one" },
        "parsons_problem" => {
          "title" => "Sort names", "question" => "Arrange these blocks",
          "blocks" => [ "def sorted(names)", "  names.sort", "end" ],
          "display_order" => [ 2, 0, 1 ], "concept" => "n_plus_one"
        }
      })
      DailyResponse.create!(user: user, daily_exercise: user.daily_exercises.last, date: Date.current,
                            answers: { "parsons_problem" => "order:0,0,0" })

      get root_path

      expect(response.body.scan('data-block-id="0"').size).to eq(1)
      expect(response.body).to include('data-block-id="1"')
      expect(response.body).to include('data-block-id="2"')
    end

    it "renders the blocks without server-side move controls, since drag is the primary input" do
      create_exercise(problem_set: {
        "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" },
        "pattern"     => { "title" => "P", "question" => "q", "why" => "w", "concept" => "n_plus_one" },
        "parsons_problem" => {
          "title" => "Sort names", "question" => "Arrange these blocks",
          "blocks" => [ "def sorted(names)", "  names.sort", "end" ],
          "display_order" => [ 2, 0, 1 ], "concept" => "n_plus_one"
        }
      })
      get root_path

      expect(response.body).to include("data-parsons-blocks")
      expect(response.body).not_to include(%(<div class="parsons-controls">))
    end

    it "ships the arrow-injection fallback and a touch delay so a stalled CDN is survivable" do
      create_exercise(problem_set: {
        "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" },
        "pattern"     => { "title" => "P", "question" => "q", "why" => "w", "concept" => "n_plus_one" },
        "parsons_problem" => {
          "title" => "Sort names", "question" => "Arrange these blocks",
          "blocks" => [ "def sorted(names)", "  names.sort", "end" ],
          "display_order" => [ 2, 0, 1 ], "concept" => "n_plus_one"
        }
      })
      get root_path

      expect(response.body).to include("parsonsAddControls")
      expect(response.body).to include("delayOnTouchOnly: true")
    end

    it "makes each block focusable and advertises the reorder shortcut, since drag is pointer-only" do
      create_exercise(problem_set: {
        "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" },
        "pattern"     => { "title" => "P", "question" => "q", "why" => "w", "concept" => "n_plus_one" },
        "parsons_problem" => {
          "title" => "Sort names", "question" => "Arrange these blocks",
          "blocks" => [ "def sorted(names)", "  names.sort", "end" ],
          "display_order" => [ 2, 0, 1 ], "concept" => "n_plus_one"
        }
      })
      get root_path

      blocks = response.body.scan(/<li class="parsons-block"[^>]*>/)
      expect(blocks.size).to eq(3)
      expect(blocks).to all(include('tabindex="0"'))
      expect(blocks).to all(include('aria-keyshortcuts="Control+ArrowUp Control+ArrowDown"'))
      expect(response.body).to include("Reorder with the arrow keys")
    end

    it "leaves the submitted read-only blocks unfocusable" do
      exercise = create_exercise(problem_set: {
        "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" },
        "pattern"     => { "title" => "P", "question" => "q", "why" => "w", "concept" => "n_plus_one" },
        "parsons_problem" => {
          "title" => "Sort names", "question" => "Arrange these blocks",
          "blocks" => [ "def sorted(names)", "  names.sort", "end" ],
          "display_order" => [ 2, 0, 1 ], "concept" => "n_plus_one"
        }
      })
      DailyResponse.create!(user: user, daily_exercise: exercise, date: exercise.date,
                            answers: { "parsons_problem" => "0,1,2" }, submitted_at: Time.current)
      get root_path

      expect(response.body).to include("parsons-list-readonly")
      expect(response.body).not_to include('tabindex="0"')
    end
  end

  describe "streak display" do    # A Wednesday, so the streak days are plain weekdays.
    let(:wednesday) { Time.utc(2026, 7, 22, 12) }

    def submit_on(date)
      exercise = DailyExercise.create!(user: user, date: date,
                                       problem_set: base_problem_set, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: date,
                            answers: { "code_review" => "a" * 20 }, submitted_at: Time.current)
    end

    it "shows the streak in the header when positive" do
      travel_to(wednesday) do
        submit_on(Date.current)
        submit_on(Date.current - 1)

        get root_path

        expect(response.body).to include("🔥 2-day streak")
      end
    end

    it "omits the streak entirely at zero" do
      travel_to(wednesday) do
        submit_on(Date.current - 2) # Mon submitted, Tue's exercise missed
        DailyExercise.create!(user: user, date: Date.current - 1,
                              problem_set: base_problem_set, generated_at: Time.current)

        get root_path

        expect(response.body).not_to include("🔥")
      end
    end
  end

  it "marks submitted code blocks for syntax highlighting even when unreviewed" do
    exercise = create_exercise
    create_response(exercise, submitted: true)

    get root_path

    expect(response.body).to include('data-hljs="ruby"')
    expect(response.body).to include("highlight.js@11.11.1/lib/core")
  end

  describe "while a regeneration is in flight" do
    def claimed_exercise
      DailyExercise.create!(user: user, date: Date.current, generated_at: 1.hour.ago,
                            problem_set: { "code_review" => { "question" => "STALE-SET-MARKER" } },
                            regenerating_since: Time.current)
    end

    it "shows the spinner instead of the stale problem set" do
      claimed_exercise

      get root_path

      expect(response.body).to include("Generating your personalized exercise set")
      expect(response.body).not_to include("STALE-SET-MARKER")
    end

    # The row is present the whole time, so an exists?-only check would report
    # the regeneration finished the instant it started.
    it "reports pending rather than ready" do
      claimed_exercise

      get dashboard_status_path

      expect(JSON.parse(response.body)["status"]).to eq("pending")
    end

    it "reports ready once the claim is released" do
      exercise = claimed_exercise
      exercise.update!(regenerating_since: nil)

      get dashboard_status_path

      expect(JSON.parse(response.body)["status"]).to eq("ready")
    end

    # A dead worker's claim must not trap the user on a spinner forever.
    it "falls through to the normal dashboard when the claim is stale" do
      problem_set = {
        "code_review" => { "question" => "STALE-SET-MARKER", "snippet" => "def a; end" },
        "pattern" => {
          "title" => "Service Objects", "why" => "Because", "question" => "When?",
          "reference" => { "tagline" => "T", "explanation" => "E",
                           "code_example" => "code", "senior_lens" => "S" }
        },
        "challenge" => { "title" => "Build", "question" => "Implement X", "starter_code" => "" }
      }
      DailyExercise.create!(user: user, date: Date.current, generated_at: 1.hour.ago,
                            problem_set: problem_set,
                            regenerating_since: DailyExercise::REGENERATION_STALE_AFTER.ago - 1.minute)

      get root_path

      expect(response.body).to include("STALE-SET-MARKER")
      expect(response.body).not_to include("Generating your personalized exercise set")
    end
  end

  describe "after a failed regeneration" do
    it "keeps the existing set and explains what went wrong" do
      ps = base_problem_set.merge("code_review" => { "question" => "keep me", "snippet" => "def a; end" })
      DailyExercise.create!(user: user, date: Date.current, generated_at: 1.hour.ago,
                            problem_set: ps)
      user.update!(last_generation_error_date: Date.current,
                   last_generation_error: "The AI provider is rate-limiting requests — try again shortly.")

      get root_path

      expect(response.body).to include("keep me")
      expect(response.body).to include("The AI provider is rate-limiting requests")
    end

    it "does not show the banner for a failure recorded on an earlier day" do
      ps = base_problem_set.merge("code_review" => { "question" => "keep me", "snippet" => "def a; end" })
      DailyExercise.create!(user: user, date: Date.current, generated_at: 1.hour.ago,
                            problem_set: ps)
      user.update!(last_generation_error_date: Date.current - 1, last_generation_error: "yesterday's problem")

      get root_path

      expect(response.body).not_to include("yesterday's problem")
    end
  end

  describe "the generation poller" do
    include ActiveSupport::Testing::TimeHelpers

    # The poller shipped with a fixed 40 attempts (120s) while the worker's
    # generation budget is GENERATION_READ_TIMEOUT (300s), so a slow but healthy
    # generation told the user to refresh while the job was still running.
    it "keeps polling for longer than a generation is allowed to take" do
      # A weekday with no exercise yet is the state that renders the spinner.
      travel_to Time.utc(2026, 8, 7, 12, 0, 0) do
        get root_path

        attempts = response.body[/MAX_ATTEMPTS = (\d+)/, 1].to_i
        interval = response.body[/POLL_INTERVAL_MS = (\d+)/, 1].to_i / 1000.0

        expect(attempts).to be_positive
        expect(attempts * interval).to be > AiService::GENERATION_READ_TIMEOUT
        expect(attempts * interval).to be > DailyExercise::REGENERATION_STALE_AFTER.to_i
      end
    end
  end

  describe "structure diagrams" do
    # Visible BEFORE answering, unlike improved_code — the whole point is
    # understanding what is being asked.
    it "renders a hidden container and the mermaid module on an unsubmitted set" do
      ps = base_problem_set
      ps["code_review"]["diagram"] = "flowchart TD\n  A[Job] --> B[(DB)]"
      create_exercise(problem_set: ps)
      login_as(user)

      get root_path

      expect(response.body).to include("mermaid-diagram")
      expect(response.body).to include("flowchart TD")
      expect(response.body).to include("mermaid@11.4.1")
      expect(response.body).to match(/securityLevel:\s*["']strict["']/)
    end

    it "renders one script for several diagrams across sections" do
      ps = base_problem_set
      ps["code_review"]["diagram"] = "flowchart TD\n  A[Job] --> B[(DB)]"
      ps["pattern"]["diagram"]     = "graph LR\n  A[Caller] --> B[Service]"
      ps["challenge"]["diagram"]   = "flowchart TD\n  A[Page] --> B[Count]"
      create_exercise(problem_set: ps)
      login_as(user)

      get root_path

      expect(response.body.scan('class="mermaid-diagram"').size).to eq(3)
      expect(response.body.scan("mermaid@11.4.1").size).to eq(1)
    end

    # The old-data guarantee: a row generated before this field existed must
    # render exactly as it did before.
    it "renders no container and no script for an exercise generated before diagrams existed" do
      create_exercise(problem_set: base_problem_set)
      login_as(user)

      get root_path

      expect(response.body).not_to include('class="mermaid-diagram"')
      expect(response.body).not_to include("mermaid@11.4.1")
    end

    # The submitted day renders a different partial than the unsubmitted one
    # (responses/_answered_sections, shared with history), so every
    # diagrammable section needs asserting here too — covering only one of
    # them would let the other two renders be deleted silently.
    it "still shows every section's diagram on a submitted day, where the questions are still on screen" do
      ps = base_problem_set
      ps["code_review"]["diagram"] = "flowchart TD\n  A[Job] --> B[(DB)]"
      ps["pattern"]["diagram"]     = "graph LR\n  A[Caller] --> B[Service]"
      ps["challenge"]["diagram"]   = "flowchart TD\n  A[Page] --> B[Count]"
      create_response(create_exercise(problem_set: ps))
      login_as(user)

      get root_path

      expect(response.body).to include("✓ Submitted")
      expect(response.body).to include("graph LR")
      expect(response.body.scan('class="mermaid-diagram"').size).to eq(3)
      expect(response.body.scan("mermaid@11.4.1").size).to eq(1)
    end
  end
end
