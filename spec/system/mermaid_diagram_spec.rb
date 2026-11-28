require "rails_helper"

# Read the DOM directly: .mermaid-diagram:empty is display:none, so have_no_css can't tell removed from empty.
RSpec.describe "Mermaid diagram failure cleanup", type: :system do
  let(:user)    { create_fake_provider_user }
  let(:weekday) { a_weekday }

  # Passes MermaidSource, so it reaches the browser, then fails Mermaid's own parse on the unclosed label.
  bad_diagram = "flowchart TD\n  A[unclosed --> B"

  # travel_to makes the server answer as of `weekday`; without it these fail every weekend.
  def start_dashboard(problem_set)
    travel_to(weekday) do
      DailyExercise.create!(user: user, date: weekday.to_date, language: "ruby_rails",
                            generated_at: Time.current, problem_set: problem_set)
      visit_as(user)
    end
  end

  def count(js) = page.evaluate_script(js)

  STRUCTURE_SUMMARIES = %q{Array.from(document.querySelectorAll("summary")).filter((s) => /Structure diagram/.test(s.textContent)).length}
  EMPTY_DIAGRAMS      = %q{Array.from(document.querySelectorAll(".mermaid-diagram")).filter((e) => !e.innerHTML.trim()).length}
  RENDERED_DIAGRAMS   = %q{document.querySelectorAll(".mermaid-diagram svg").length}

  [ false, true ].each do |initial_diagram|
    it "renders an appended diagram without replacing existing content, initial diagram=#{initial_diagram}" do
      travel_to(weekday) do
        page.driver.with_playwright_page do |pw|
          pw.route("**/mermaid@*/**", ->(route, _request) {
            route.fulfill(status: 200, contentType: "application/javascript", body: <<~JS)
              export default {
                initialize(options) { if (options.securityLevel !== 'strict') throw new Error('Unsafe configuration'); },
                async parse() {},
                async render() { return { svg: '<svg xmlns="http://www.w3.org/2000/svg"><text>Diagram</text></svg>' }; }
              };
            JS
          })
        end
        original = FakeService::EXERCISE_PROBLEM_SET.fetch("pattern").deep_dup
        original["diagram"] = "flowchart TD\n  A[Original] --> B[Result]" if initial_diagram
        exercise = user.daily_exercises.create!(date: Date.current, language: "ruby_rails", generated_at: Time.current,
          problem_set: { "pattern" => original }, section_order: %w[pattern])
        visit_as(user)
        wait_for_js
        wait_for { count(RENDERED_DIAGRAMS) == 1 } if initial_diagram
        fill_in_answer("pattern", "Keep the answer while adding a diagram.")
        page.execute_script(<<~JS)
          window.keptAnswer = document.querySelector('textarea[data-field="pattern"]');
          window.keptDiagram = document.querySelector('.mermaid-diagram svg');
        JS
        added = FakeService::EXERCISE_PROBLEM_SET.fetch("code_review").deep_dup
        added["diagram"] = "flowchart TD\n  C[Added] --> D[Result]"
        exercise.update!(problem_set: exercise.problem_set.merge("code_review" => added), section_order: %w[pattern code_review])

        page.execute_script('window.dispatchEvent(new Event("focus"))')

        expect(page).to have_css('[data-section-fold="code_review"]')
        wait_for { count(RENDERED_DIAGRAMS) == (initial_diagram ? 2 : 1) }
        expect(page.evaluate_script('window.keptAnswer === document.querySelector("textarea[data-field=pattern]")')).to be(true)
        expect(find('textarea[data-field="pattern"]').value).to eq("Keep the answer while adding a diagram.")
        if initial_diagram
          expect(page.evaluate_script('window.keptDiagram === document.querySelector(".mermaid-diagram svg")')).to be(true)
        end
        expect(count(EMPTY_DIAGRAMS)).to eq(0)
      end
    end
  end

  it "removes the whole disclosure it owns when the diagram cannot be parsed" do
    ps = FakeService::EXERCISE_PROBLEM_SET.deep_dup
    ps["code_review"]["diagram"] = bad_diagram
    start_dashboard(ps)
    expect(page).to have_content(/Code Review/i)

    wait_for { count(STRUCTURE_SUMMARIES).zero? }
    expect(count(EMPTY_DIAGRAMS)).to eq(0)
  end

  it "renders the diagram inside its own disclosure when the syntax is valid" do
    ps = FakeService::EXERCISE_PROBLEM_SET.deep_dup
    ps["code_review"]["diagram"] = "flowchart TD\n  A[Job] --> B[(DB)]"
    start_dashboard(ps)
    expect(page).to have_content(/Code Review/i)

    wait_for { count(RENDERED_DIAGRAMS) == 1 }
    expect(count(STRUCTURE_SUMMARIES)).to eq(1)
    expect(count(EMPTY_DIAGRAMS)).to eq(0)
  end

  # Cleanup that removes the nearest <details> unconditionally would delete a reference box the diagram doesn't own.
  it "takes out only its own div when a failed diagram sits in a box it does not own" do
    ps = FakeService::EXERCISE_PROBLEM_SET.deep_dup.except("challenge")
    ps["architecture"] = {
      "title" => "Datastore", "question" => "Which approach?", "scenario" => "10x traffic",
      "reference" => {
        "tagline" => "Pick for the write path", "explanation" => "Sharding trades joins for throughput",
        "tradeoffs" => [ "Sharding complicates joins" ], "senior_lens" => "Measure first",
        "diagram" => bad_diagram
      }
    }
    start_dashboard(ps)
    expect(page).to have_content(/Datastore/i)

    wait_for { count(EMPTY_DIAGRAMS).zero? }
    expect(page).to have_css("details.ref", text: /Reference/i)
    expect(count(%q{document.body.textContent.includes("Sharding complicates joins")})).to be(true)
  end
end
