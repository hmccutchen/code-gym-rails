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

  # Mermaid loads from a CDN, so cleanup lands after an unpredictable delay; poll rather than sleep.
  def wait_until(timeout: 15)
    deadline = Time.current + timeout
    loop do
      value = yield
      return value if value
      raise "condition never became true within #{timeout}s" if Time.current > deadline
      sleep 0.2
    end
  end

  def count(js) = page.evaluate_script(js)

  STRUCTURE_SUMMARIES = %q{Array.from(document.querySelectorAll("summary")).filter((s) => /Structure diagram/.test(s.textContent)).length}
  EMPTY_DIAGRAMS      = %q{Array.from(document.querySelectorAll(".mermaid-diagram")).filter((e) => !e.innerHTML.trim()).length}
  RENDERED_DIAGRAMS   = %q{document.querySelectorAll(".mermaid-diagram svg").length}

  it "removes the whole disclosure it owns when the diagram cannot be parsed" do
    ps = FakeService::EXERCISE_PROBLEM_SET.deep_dup
    ps["code_review"]["diagram"] = bad_diagram
    start_dashboard(ps)
    expect(page).to have_content(/Code Review/i, wait: 10)

    wait_until { count(STRUCTURE_SUMMARIES).zero? }
    expect(count(EMPTY_DIAGRAMS)).to eq(0)
  end

  it "renders the diagram inside its own disclosure when the syntax is valid" do
    ps = FakeService::EXERCISE_PROBLEM_SET.deep_dup
    ps["code_review"]["diagram"] = "flowchart TD\n  A[Job] --> B[(DB)]"
    start_dashboard(ps)
    expect(page).to have_content(/Code Review/i, wait: 10)

    wait_until { count(RENDERED_DIAGRAMS) == 1 }
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
    expect(page).to have_content(/Datastore/i, wait: 10)

    wait_until { count(EMPTY_DIAGRAMS).zero? }
    # The box that merely contained the diagram, and its content, must survive.
    expect(page).to have_css("details.ref", text: /Reference/i)
    expect(count(%q{document.body.innerHTML.includes("Sharding complicates joins")})).to be(true)
  end
end
