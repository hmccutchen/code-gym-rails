require "rails_helper"

RSpec.describe "History", type: :request do
  let(:user) { create_user_with_key }

  def create_session_for(owner, date:, submitted: true, reviewed: false, rating: nil, concept_tags: {}, section_ratings: nil, legacy_rating: nil)
    exercise = DailyExercise.create!(
      user: owner, date: date,
      problem_set: {
        "code_review" => { "question" => "q-#{date}", "snippet" => "s" },
        "pattern" => { "title" => "Pat-#{date}", "question" => "pattern-q-#{date}" },
        "challenge" => { "question" => "challenge-q-#{date}" }
      },
      generated_at: Time.current
    )
    # If a rating is provided and section_ratings is not explicitly set, use the rating for all sections
    final_section_ratings = if section_ratings.present?
      section_ratings
    elsif rating.present? || legacy_rating.present?
      val = rating || legacy_rating
      { "code_review" => val, "pattern" => val, "challenge" => val }
    else
      {}
    end
    DailyResponse.create!(
      user: owner, daily_exercise: exercise, date: date,
      answers: { "code_review" => "Answer with plenty of substance" },
      submitted_at: submitted ? Time.current : nil,
      section_ratings: final_section_ratings,
      concept_tags: concept_tags,
      ai_review: reviewed ? { "code_review" => { "rating" => "solid", "correct" => "Spotted the issue on #{date}" } } : nil
    )
  end

  describe "parsons_problem third section, submitted" do
    it "renders the submitted order read-only, without the reorder controls" do
      exercise = DailyExercise.create!(
        user: user, date: 1.day.ago.to_date, generated_at: Time.current, language: "ruby_rails",
        problem_set: {
          "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" },
          "pattern"     => { "title" => "P", "question" => "q", "why" => "w", "concept" => "n_plus_one" },
          "parsons_problem" => {
            "title" => "Sort names", "question" => "Arrange these blocks",
            "blocks" => [ "def sorted(names)", "  names.sort", "end" ],
            "display_order" => [ 0, 1, 2 ], "concept" => "n_plus_one"
          }
        }
      )
      DailyResponse.create!(
        user: user, daily_exercise: exercise, date: exercise.date, submitted_at: Time.current,
        answers: { "code_review" => "x" * 20, "pattern" => "x" * 20, "parsons_problem" => "order:0,1,2" },
        section_ratings: { "code_review" => "right_level", "pattern" => "right_level", "parsons_problem" => "right_level" }
      )
      login_as(user)
      get history_path

      expect(response.body).to include("Parsons Problem: Sort names")
      expect(response.body).not_to include("parsons-move-up")
      expect(response.body).to include("parsons-correct")
    end

    it "renders an out-of-range block id as skipped instead of an empty or wrapped block" do
      exercise = DailyExercise.create!(
        user: user, date: 1.day.ago.to_date, generated_at: Time.current, language: "ruby_rails",
        problem_set: {
          "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" },
          "pattern"     => { "title" => "P", "question" => "q", "why" => "w", "concept" => "n_plus_one" },
          "parsons_problem" => {
            "title" => "Sort names", "question" => "Arrange these blocks",
            "blocks" => [ "def sorted(names)", "  names.sort", "end" ],
            "display_order" => [ 0, 1, 2 ], "concept" => "n_plus_one"
          }
        }
      )
      DailyResponse.create!(
        user: user, daily_exercise: exercise, date: exercise.date, submitted_at: Time.current,
        answers: { "code_review" => "x" * 20, "parsons_problem" => "order:-1,9,1" }
      )
      login_as(user)
      get history_path

      parsons_list = response.body[/<ol class="parsons-list parsons-list-readonly">.*?<\/ol>/m]
      expect(parsons_list.scan("(skipped)").size).to eq(2)
      expect(parsons_list).to include("names.sort")
    end
  end

  describe "fourth-slot rendering" do
    def create_exercise_with_fourth(fourth_key, fourth_section)
      DailyExercise.create!(
        user: user, date: 1.day.ago.to_date, generated_at: Time.current,
        problem_set: {
          "code_review" => { "question" => "q", "snippet" => "s" },
          "pattern" => { "title" => "Pat", "question" => "pattern-q" },
          "challenge" => { "question" => "challenge-q" },
          fourth_key => fourth_section
        }
      )
    end

    it "renders a submitted plan_review fourth section with its label and answer" do
      exercise = create_exercise_with_fourth("plan_review", {
        "title" => "Cache plan", "question" => "What's wrong?",
        "plan_excerpt" => "Cache for 300 seconds. Also add an admin cache-clear endpoint."
      })
      DailyResponse.create!(
        user: user, daily_exercise: exercise, date: exercise.date, submitted_at: Time.current,
        answers: { "code_review" => "x" * 20, "plan_review" => "This ignores cache invalidation on writes." }
      )

      login_as(user)
      get history_path

      expect(response.body).to include("4 — Plan Review")
      expect(response.body).to include("This ignores cache invalidation on writes.")
    end

    it "renders a submitted ambiguity_hunt fourth section, never leaking planted_ambiguities" do
      exercise = create_exercise_with_fourth("ambiguity_hunt", {
        "title" => "Leaderboard ask", "question" => "What's unclear?",
        "request" => "Add a leaderboard to the dashboard.",
        "planted_ambiguities" => [ "Which metric ranks users is unstated", "Tie-breaking is unstated" ]
      })
      DailyResponse.create!(
        user: user, daily_exercise: exercise, date: exercise.date, submitted_at: Time.current,
        answers: { "code_review" => "x" * 20, "ambiguity_hunt" => "Which metric ranks users, and how are ties broken?" }
      )

      login_as(user)
      get history_path

      expect(response.body).to include("4 — Ambiguity Hunt")
      expect(response.body).to include("Which metric ranks users, and how are ties broken?")
      expect(response.body).not_to include("Which metric ranks users is unstated")
      expect(response.body).not_to include("Tie-breaking is unstated")
    end
  end

  describe "GET /history" do
    it "requires login" do
      get history_path
      expect(response).to redirect_to(login_path)
    end

    it "never renders improved_code for the architecture section" do
      exercise = DailyExercise.create!(
        user: user, date: 1.day.ago.to_date, generated_at: Time.current, language: "ruby_rails",
        problem_set: { "architecture" => { "title" => "A", "question" => "arch-q" } }
      )
      DailyResponse.create!(
        user: user, daily_exercise: exercise, date: 1.day.ago.to_date,
        answers: { "architecture" => "I'd shard because of the write volume" },
        submitted_at: Time.current,
        concept_tags: { "architecture" => "other" },
        ai_review: { "architecture" => { "rating" => "solid", "improved_code" => "arch_improved_marker" } }
      )

      login_as(user)
      get history_path

      expect(response.body).not_to include("arch_improved_marker")
    end

    def architecture_session(diagram:)
      reference = { "tagline" => "t", "explanation" => "e", "tradeoffs" => [ "a" ], "senior_lens" => "s" }
      reference["diagram"] = diagram unless diagram.nil?

      exercise = DailyExercise.create!(
        user: user, date: 1.day.ago.to_date, generated_at: Time.current, language: "ruby_rails",
        problem_set: { "architecture" => {
          "title" => "Datastore", "question" => "Which approach?", "scenario" => "10x traffic",
          "reference" => reference
        } }
      )
      DailyResponse.create!(
        user: user, daily_exercise: exercise, date: 1.day.ago.to_date,
        answers: { "architecture" => "I would shard because of write volume" },
        submitted_at: Time.current
      )
    end

    it "renders a collapsed disclosure and the mermaid module when a diagram is present" do
      architecture_session(diagram: "flowchart TD\n  A[Client] --> B[API]")
      login_as(user)
      get history_path

      # Architecture's diagram is collapsible: false (it already lives inside
      # its own "Reference — tradeoffs" <details class="ref">), so it must
      # NOT get its own nested disclosure — only the outer one.
      expect(response.body.scan('<details class="ref">').size).to eq(1)
      expect(response.body).not_to include("🗺️ Structure diagram")
      expect(response.body).to include("mermaid-diagram")
      expect(response.body).to include("flowchart TD")
      expect(response.body).to include("cdn.jsdelivr.net")
      expect(response.body).to match(/securityLevel:\s*["']strict["']/)

      # collapsible: false means this partial did not create the enclosing
      # <details> (that's architecture's own pre-existing tradeoffs box), so
      # the div itself must carry no data-owns-details attribute — a failed
      # parse/render must remove only the .mermaid-diagram div, never that
      # outer, unrelated box. Scoped to the div's own tag, since the shared
      # module script's comments legitimately mention the attribute by name.
      diagram_div = response.body[/<div class="mermaid-diagram"[^>]*>/]
      expect(diagram_div).to be_present
      expect(diagram_div).not_to include("data-owns-details")
    end

    it "renders no container and no mermaid script when the diagram is an empty string" do
      architecture_session(diagram: "")
      login_as(user)
      get history_path

      # The .mermaid-diagram CSS rule itself is global (defined once in the
      # layout's <style> block, like every other section style), so it is
      # present on every page regardless of content. What must NOT appear is
      # an actual container element or the mermaid script.
      expect(response.body).not_to include('<div class="mermaid-diagram"')
      expect(response.body).not_to include("mermaid@11.4.1")
    end

    it "renders no container and no mermaid script for an exercise generated before diagrams existed" do
      architecture_session(diagram: nil)
      login_as(user)
      get history_path

      # The .mermaid-diagram CSS rule itself is global (defined once in the
      # layout's <style> block, like every other section style), so it is
      # present on every page regardless of content. What must NOT appear is
      # an actual container element or the mermaid script.
      expect(response.body).not_to include('<div class="mermaid-diagram"')
      expect(response.body).not_to include("mermaid@11.4.1")
    end

    it "emits the ai_review autosave script and the mermaid module exactly once across multiple entries" do
      # shared/_ai_review renders once per reviewed entry, and
      # shared/_mermaid_diagram's module renders once per architecture
      # section with a diagram — both would otherwise ship one
      # duplicate ~4-5 KB script per entry. Verifies they're deduped into the
      # layout's shared :page_scripts region instead.
      3.times { |i| create_session_for(user, date: (i + 5).days.ago.to_date, reviewed: true) }
      architecture_session(diagram: "flowchart TD\n  A[Client] --> B[API]")

      login_as(user)
      get history_path

      expect(response.body.scan("Autosaves on blur.").size).to eq(1)
      # Check for mermaid script specifically, since highlight.js script also uses cdn.jsdelivr.net
      expect(response.body.scan("mermaid@11.4.1").size).to eq(1)
    end

    it "renders improved_code for a visible pattern section" do
      exercise = DailyExercise.create!(
        user: user, date: 1.day.ago.to_date, generated_at: Time.current, language: "ruby_rails",
        problem_set: {
          "code_review" => { "question" => "q", "snippet" => "s" },
          "pattern" => { "title" => "Pat", "question" => "pattern-q" },
          "challenge" => { "question" => "challenge-q" }
        }
      )
      DailyResponse.create!(
        user: user, daily_exercise: exercise, date: 1.day.ago.to_date,
        answers: { "pattern" => "Extract a service object" },
        submitted_at: Time.current,
        concept_tags: { "pattern" => "other" },
        ai_review: { "pattern" => { "rating" => "solid", "improved_code" => "pattern_improved_marker" } }
      )

      login_as(user)
      get history_path

      expect(response.body).to include("pattern_improved_marker")
    end

    # A revised implementation plan is prose. Sending it through the shared
    # code renderer syntax-highlights English as Ruby and labels it "Improved
    # code" — see ExerciseSection::PlanReview.improved_code_prose?.
    it "renders plan_review's improved_code as a labelled prose plan, not highlighted source" do
      exercise = DailyExercise.create!(
        user: user, date: 1.day.ago.to_date, generated_at: Time.current, language: "ruby_rails",
        problem_set: {
          "code_review" => { "question" => "q", "snippet" => "s" },
          "pattern"     => { "title" => "Pat", "question" => "pattern-q" },
          "challenge"   => { "question" => "challenge-q" },
          "plan_review" => { "title" => "Plan", "question" => "plan-q", "plan_excerpt" => "the plan" }
        }
      )
      DailyResponse.create!(
        user: user, daily_exercise: exercise, date: 1.day.ago.to_date,
        answers: { "plan_review" => "The migration step is a behavior change" },
        submitted_at: Time.current,
        concept_tags: { "plan_review" => "other" },
        ai_review: { "plan_review" => { "rating" => "solid", "improved_code" => "revised_plan_marker" } }
      )

      login_as(user)
      get history_path

      expect(response.body).to include("Revised plan")
      expect(response.body).to include(%(<div class="plan-excerpt" style="margin-top:.4rem">revised_plan_marker</div>))
      expect(response.body).not_to include(%(<code data-hljs="ruby">revised_plan_marker</code>))
    end

    it "lists only the current user's submitted responses, newest first" do
      other = create_user_with_key(email: "other@example.com", name: "Other")
      old   = create_session_for(user, date: 3.days.ago.to_date, reviewed: true, section_ratings: {}, legacy_rating: "too_hard")
      newer = create_session_for(user, date: 1.day.ago.to_date)
      create_session_for(user, date: Date.current, submitted: false)   # draft — excluded
      create_session_for(other, date: 2.days.ago.to_date)              # other user — excluded

      login_as(user)
      get history_path

      expect(response.body).to include(newer.date.strftime("%A, %B %-d, %Y"))
      expect(response.body).to include(old.date.strftime("%A, %B %-d, %Y"))
      expect(response.body).not_to include(Date.current.strftime("%A, %B %-d, %Y"))
      expect(response.body).not_to include(2.days.ago.to_date.strftime("%A, %B %-d, %Y"))
      expect(response.body.index(newer.date.strftime("%A, %B %-d, %Y")))
        .to be < response.body.index(old.date.strftime("%A, %B %-d, %Y"))
    end

    it "shows rating, concept tags, review content for reviewed entries, and a fallback otherwise" do
      create_session_for(user, date: 3.days.ago.to_date, reviewed: true, section_ratings: { "code_review" => "too_hard", "pattern" => "too_hard", "challenge" => "too_hard" },
                         concept_tags: { "code_review" => "n_plus_one" })
      create_session_for(user, date: 1.day.ago.to_date)

      login_as(user)
      get history_path

      expect(response.body).to include("Code review: too hard")
      expect(response.body).to include("Pattern: too hard")
      expect(response.body).to include("Challenge: too hard")
      expect(response.body).to include("N plus one")
      expect(response.body).to include("What you got right")
      expect(response.body).to include("Spotted the issue on #{3.days.ago.to_date}")
      expect(response.body).to include("No AI review requested.")
      expect(response.body).to include("1/3 sections")
    end

    it "renders a submitted entry's concept-reference dropdown read-only" do
      exercise = DailyExercise.create!(
        user: user, date: 1.day.ago.to_date,
        problem_set: {
          "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" },
          "pattern" => { "title" => "Pat", "question" => "pattern-q" },
          "challenge" => { "question" => "challenge-q" }
        },
        generated_at: Time.current
      )
      DailyResponse.create!(user: user, daily_exercise: exercise, date: 1.day.ago.to_date,
                            answers: { "code_review" => "Answer with plenty of substance" },
                            submitted_at: Time.current)
      ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails",
                               tagline: "Avoid the loop query", explanation: "e", code_example: "c", senior_lens: "l")

      login_as(user)
      get history_path

      expect(response.body).to include("Reference — N plus one: how it works")
      expect(response.body).not_to include('<details class="ref" open>')
    end

    # One reference can render several times on this page. The script keys the
    # framings it has been shown by reference id rather than by container so
    # the cap holds across every copy — these are the copies.
    it "gives every copy of one reference the same reference id to share a cap by" do
      reference = ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails",
                                           tagline: "t", explanation: "e", code_example: "c", senior_lens: "l")
      [ 1, 2 ].each do |days_ago|
        exercise = DailyExercise.create!(
          user: user, date: days_ago.days.ago.to_date, generated_at: Time.current,
          problem_set: { "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" } }
        )
        DailyResponse.create!(user: user, daily_exercise: exercise, date: days_ago.days.ago.to_date,
                              answers: { "code_review" => "Answer with plenty of substance" },
                              submitted_at: Time.current)
      end

      login_as(user)
      get history_path

      expect(response.body.scan(%(data-reference-id="#{reference.id}")).size).to eq(2)
      expect(response.body.scan(%(class="btn btn-ghost btn-sm explain-concept-differently")).size).to eq(2)
    end

    it "renders each entry's problems and the user's answers" do
      session = create_session_for(user, date: 1.day.ago.to_date)

      login_as(user)
      get history_path

      expect(response.body).to include("q-#{session.date}")
      expect(response.body).to include("Answer with plenty of substance")
      expect(response.body).to include("Problems &amp; answers")
    end

    it "anchors each entry by response id" do
      session = create_session_for(user, date: 1.day.ago.to_date)

      login_as(user)
      get history_path

      expect(response.body).to include(%(id="response-#{session.id}"))
    end

    it "folds every entry's problems and opens the newest entry's review" do
      create_session_for(user, date: 1.day.ago.to_date, reviewed: true)
      create_session_for(user, date: 3.days.ago.to_date, reviewed: true)

      login_as(user)
      get history_path

      # Two entries, no open problems block, exactly one open review — the first.
      expect(response.body.scan(/<details class="answers" open>/).size).to eq(0)
      expect(response.body.scan(/<details class="answers">/).size).to eq(2)
      expect(response.body.scan(/<details class="review" open>/).size).to eq(1)
    end

    it "renders an entry whose stored problem_set is missing sections, without breaking the page" do
      sparse = DailyExercise.create!(
        user: user, date: 5.days.ago.to_date, generated_at: Time.current,
        problem_set: { "code_review" => { "question" => "only-section", "snippet" => "s" } }
      )
      DailyResponse.create!(user: user, daily_exercise: sparse, date: 5.days.ago.to_date,
                            answers: { "code_review" => "Answer with plenty of substance" },
                            submitted_at: Time.current)
      intact = create_session_for(user, date: 1.day.ago.to_date)

      login_as(user)
      get history_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("only-section")
      # The malformed row must not take the rest of the page down with it.
      expect(response.body).to include("q-#{intact.date}")
    end

    it "renders an array-shaped review field as a list, one item per point" do
      session = create_session_for(user, date: 1.day.ago.to_date, reviewed: true)
      session.update!(ai_review: {
        "code_review" => {
          "rating"  => "solid",
          "missed"  => [ "The missing index on user_id", "No transaction around the writes" ]
        }
      })

      login_as(user)
      get history_path

      expect(response.body).to include("<li>The missing index on user_id</li>")
      expect(response.body).to include("<li>No transaction around the writes</li>")
    end

    it "renders a legacy string-shaped review field as a single-item list" do
      create_session_for(user, date: 2.days.ago.to_date, reviewed: true)

      login_as(user)
      get history_path

      expect(response.body).to include("<li>Spotted the issue on #{2.days.ago.to_date}</li>")
    end

    it "renders the self-explanation prompt on a reviewed entry" do
      create_session_for(user, date: 1.day.ago.to_date, reviewed: true)
      login_as(user)
      get history_path

      expect(response.body).to include("Break this fix into 2-3 steps and name what each one does.")
      expect(response.body).to include("self-explanation-input")
    end

    it "marks code_review and improved_code with the exercise's highlight.js language" do
      session = create_session_for(user, date: 1.day.ago.to_date, reviewed: true)
      session.update!(ai_review: { "code_review" => { "rating" => "solid", "improved_code" => "User.includes(:posts)" } })

      login_as(user)
      get history_path

      # create_session_for's challenge section has no starter_code, so the only
      # two data-hljs="ruby" occurrences on this page are the code_review
      # snippet (responses/_answered_sections) and improved_code (shared/_ai_review).
      expect(response.body.scan('data-hljs="ruby"').size).to eq(2)
    end

    it "marks a javascript exercise's snippet as javascript, not ruby" do
      exercise = DailyExercise.create!(
        user: user, date: 1.day.ago.to_date, generated_at: Time.current, language: "javascript",
        problem_set: { "code_review" => { "question" => "q", "snippet" => "const x = 1;" } }
      )
      DailyResponse.create!(
        user: user, daily_exercise: exercise, date: 1.day.ago.to_date,
        answers: { "code_review" => "an answer with real substance" }, submitted_at: Time.current
      )

      login_as(user)
      get history_path

      expect(response.body).to include('data-hljs="javascript"')
      expect(response.body).not_to include('data-hljs="ruby"')
    end

    it "never marks an architecture concept reference's pseudocode example for highlighting" do
      exercise = DailyExercise.create!(
        user: user, date: 1.day.ago.to_date, generated_at: Time.current, language: "ruby_rails",
        problem_set: { "architecture" => { "title" => "A", "question" => "arch-q", "concept" => "scaling_bottlenecks" } }
      )
      DailyResponse.create!(
        user: user, daily_exercise: exercise, date: 1.day.ago.to_date,
        answers: { "architecture" => "I would shard because of write volume" }, submitted_at: Time.current
      )
      ConceptReference.create!(concept: "scaling_bottlenecks", language: "architecture",
        tagline: "t", explanation: "e", code_example: "shard_by(:tenant_id)  # pseudocode", senior_lens: "s")

      login_as(user)
      get history_path

      expect(response.body).to include("shard_by(:tenant_id)")
      # Check for data-hljs as an HTML attribute, not in script code
      expect(response.body).not_to include('data-hljs="')
    end

    it "loads the highlight.js script exactly once across multiple reviewed entries" do
      3.times do |i|
        session = create_session_for(user, date: (i + 5).days.ago.to_date, reviewed: true)
        session.update!(ai_review: { "code_review" => { "rating" => "solid", "improved_code" => "improved" } })
      end

      login_as(user)
      get history_path

      expect(response.body.scan("highlight.js@11.11.1/lib/core").size).to eq(1)
    end

    it "marks a reviewed session with no improved_code in any section and still loads the script" do
      session = create_session_for(user, date: 1.day.ago.to_date, reviewed: true)
      # Update to ensure NO improved_code in any section
      session.update!(ai_review: { "code_review" => { "rating" => "solid", "correct" => "Good job" } })

      login_as(user)
      get history_path

      # The code_review snippet should be marked
      expect(response.body).to include('data-hljs="ruby"')
      # The script should load even though there's no improved_code
      expect(response.body).to include("highlight.js@11.11.1/lib/core")
    end
  end

  describe "review summary label" do
    it "names the user's provider on the history review summary" do
      user.update!(provider: "gemini")
      login_as(user)
      create_session_for(user, date: Date.current, reviewed: true)

      get history_path

      expect(response.body).to include("Gemini&#39;s review")
      expect(response.body).not_to include("Claude&#39;s review")
    end
  end

  describe "mobile gutter" do
    it "makes history entries full-bleed on phones without letting nested sections break out again" do
      login_as(user)
      create_session_for(user, date: Date.current)

      get history_path

      # The layout's own mobile rule also renders here, so matching the
      # breakpoint alone would pass even with this page's block deleted. Both
      # declarations are pinned to their selectors: the entry breaks out, and
      # the nested cards are reset so they don't break out a second time.
      expect(response.body).to match(/@media \(max-width: 600px\) \{\s*\.history-entry \{[^}]*margin-inline: -1\.5rem;/)
      expect(response.body).to match(/\.history-entry \.section \{[^}]*margin-inline: 0;/)
    end
  end

  describe "pagination" do
    def create_sessions(count)
      (0...count).map { |i| create_session_for(user, date: (i + 1).days.ago.to_date) }
    end

    def formatted(session)
      session.date.strftime("%A, %B %-d, %Y")
    end

    def pagination_nav
      response.body[/<nav class="pagination".*?<\/nav>/m]
    end

    it "shows the ten newest sessions on page 1 and the eleventh on page 2" do
      sessions = create_sessions(11)
      login_as(user)

      get history_path
      expect(response.body).to include(formatted(sessions[0]))
      expect(response.body).to include(formatted(sessions[9]))
      expect(response.body).not_to include(formatted(sessions[10]))

      get history_path(page: 2)
      expect(response.body).to include(formatted(sessions[10]))
      expect(response.body).not_to include(formatted(sessions[0]))
    end

    it "reports the total session count on every page, not the page size" do
      create_sessions(11)
      login_as(user)

      get history_path
      expect(response.body).to include("11 submitted sessions")

      get history_path(page: 2)
      expect(response.body).to include("11 submitted sessions")
    end

    it "renders no nav when every session fits on one page" do
      create_sessions(10)
      login_as(user)

      get history_path

      expect(response.body).not_to include('class="pagination"')
    end

    it "links forward from the first page and back from the last" do
      create_sessions(11)
      login_as(user)

      get history_path
      expect(pagination_nav).to include("Page 1 of 2")
      expect(pagination_nav).to include(%(href="#{history_path(page: 2)}"))

      get history_path(page: 2)
      expect(pagination_nav).to include("Page 2 of 2")
      expect(pagination_nav).to include(%(href="#{history_path(page: 1)}"))
    end

    it "redirects an out-of-range page to the last real page" do
      create_sessions(11)
      login_as(user)

      get history_path(page: 99)

      expect(response).to redirect_to(history_path(page: 2))
    end

    it "redirects to the bare /history URL when the last page is page 1" do
      create_sessions(3)
      login_as(user)

      get history_path(page: 99)

      expect(response).to redirect_to(history_path)
    end

    it "serves page 1 for a non-numeric page rather than erroring" do
      sessions = create_sessions(11)
      login_as(user)

      get history_path(page: "abc")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(formatted(sessions[0]))
    end

    it "clamps zero and negative page numbers to page 1" do
      sessions = create_sessions(11)
      login_as(user)

      get history_path(page: 0)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(formatted(sessions[0]))

      get history_path(page: -1)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(formatted(sessions[0]))
    end

    it "auto-opens the newest entry's review on page 1 and nothing on later pages" do
      11.times { |i| create_session_for(user, date: (i + 1).days.ago.to_date, reviewed: true) }
      login_as(user)

      get history_path
      expect(response.body.scan(/<details class="review" open>/).size).to eq(1)

      get history_path(page: 2)
      expect(response.body.scan(/<details class="review" open>/).size).to eq(0)
    end

    it "still renders the empty state when the user has no sessions at all" do
      login_as(user)

      get history_path

      expect(response.body).to include("No submitted sessions yet.")
      expect(response.body).not_to include('class="pagination"')
    end
  end
end
