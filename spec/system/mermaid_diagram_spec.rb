require "rails_helper"

# The "a failed diagram leaves no trace" guarantee used to be structural: the
# container was display:none by default and revealed only on a successful
# render, so no JS path could produce a broken box. Making diagrams collapsible
# inverted that — the disclosure now renders visible, and the module script has
# to REMOVE it on failure. That moves the guarantee out of CSS and into
# JavaScript, where only a real browser can verify it.
#
# These assertions read the DOM directly rather than using have_no_css, because
# .mermaid-diagram:empty is display:none — a Capybara visibility check passes
# identically whether the element was removed or is merely still empty, which is
# exactly the distinction these specs exist to draw.
RSpec.describe "Mermaid diagram failure cleanup", type: :system do
  let(:user)    { create_fake_provider_user }
  let(:weekday) { a_weekday }

  bad_diagram = "not mermaid syntax @@@ <<< >>>"

  # Travelled here rather than around each example body, the way the sibling
  # specs do it: this spec already enters the page in one place, and that place
  # is the only one that knows about `weekday`, so dating the record and setting
  # the browser's clock together is what stops the two disagreeing.
  #
  # Without it these examples pass Monday to Friday — where a_weekday IS today —
  # and fail every weekend, when a_weekday jumps forward to the next Monday
  # while the browser stays on the real day and the dashboard renders its "no
  # exercises on weekends" empty state instead of the set.
  def start_dashboard(problem_set)
    travel_to(weekday) do
      DailyExercise.create!(user: user, date: weekday.to_date, language: "ruby_rails",
                            generated_at: Time.current, problem_set: problem_set)
      visit_as(user)
    end
  end

  # The module script imports Mermaid from a CDN, so cleanup lands after an
  # unpredictable delay; poll rather than sleep on a guessed duration.
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

    # Gone entirely — not a still-empty box, and not a clickable triangle with
    # nothing behind it.
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

  # The regression this guards already happened once during development:
  # cleanup that walks up to the nearest <details> unconditionally deletes
  # architecture's "Reference — tradeoffs" box, destroying content the diagram
  # never owned. collapsible: false is what makes removing only the div the
  # correct blast radius.
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
