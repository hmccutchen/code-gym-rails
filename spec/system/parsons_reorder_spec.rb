require "rails_helper"

RSpec.describe "Parsons reorder controls", type: :system do
  let(:user)    { create_fake_provider_user }
  let(:weekday) { a_weekday }

  # FakeService always loses parsons_problem to architecture in DailyPlan's
  # precedence order, so relying on generation would never produce this section.
  def seed_parsons_exercise
    DailyExercise.create!(
      user: user,
      date: weekday.to_date,
      language: "ruby_rails",
      generated_at: Time.current,
      problem_set: {
        "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" },
        "pattern"     => { "title" => "P", "question" => "q", "why" => "w", "concept" => "n_plus_one" },
        "parsons_problem" => {
          "title" => "Sort names", "question" => "Arrange these blocks",
          "blocks" => [ "def sorted(names)", "  names.sort", "end" ],
          "display_order" => [ 2, 0, 1 ], "concept" => "n_plus_one"
        }
      }
    )
  end

  SORTABLE_URL = "**cdn.jsdelivr.net**sortable**"

  # Both branches of the fallback are decided by whether one CDN request
  # succeeds, so intercepting that request is what makes either branch testable
  # at all — otherwise the outcome is whatever the CI runner's network allows,
  # and the failure branch is never exercised. The stub only needs `create`:
  # the partial destructures the default export and calls nothing else on it.
  def stub_sortable_cdn(outcome)
    page.driver.with_playwright_page do |pw|
      pw.route(SORTABLE_URL, ->(route, _request) {
        case outcome
        when :blocked then route.abort
        when :loaded  then route.fulfill(
          status: 200,
          contentType: "application/javascript",
          body: "export default { create() {} };"
        )
        end
      })
    end
  end

  def visit_seeded_dashboard(cdn:)
    seed_parsons_exercise
    stub_sortable_cdn(cdn)
    visit_as(user)
    expect(page).to have_css("ol[data-parsons-blocks][data-parsons-wired]", wait: 10)
  end

  def block_ids
    all("ol[data-parsons-blocks] .parsons-block").map { |li| li["data-block-id"] }
  end

  def hidden_answer
    find("textarea[data-field='parsons_problem']", visible: :all).value
  end

  it "shows no arrow buttons once drag is available" do
    travel_to(weekday) do
      visit_seeded_dashboard(cdn: :loaded)

      expect(page).to have_css("ol[data-parsons-blocks][data-sortable-done]", wait: 10)
      expect(page).to have_no_css(".parsons-move-up")
      expect(page).to have_no_css(".parsons-move-down")
    end
  end

  it "injects working arrows when the CDN is unreachable" do
    travel_to(weekday) do
      visit_seeded_dashboard(cdn: :blocked)

      expect(page).to have_css(".parsons-move-up", count: 3, wait: 10)
      expect(page).to have_no_css("ol[data-parsons-blocks][data-sortable-done]")

      all(".parsons-move-down").first.click

      expect(block_ids).to eq([ "0", "2", "1" ])
      expect(hidden_answer).to eq("order:0,2,1")
    end
  end

  it "reorders with the keyboard, since dragging is pointer-only" do
    travel_to(weekday) do
      visit_seeded_dashboard(cdn: :loaded)
      expect(block_ids).to eq([ "2", "0", "1" ])

      find("ol[data-parsons-blocks] .parsons-block", match: :first).send_keys(%i[control down])

      expect(block_ids).to eq([ "0", "2", "1" ])
      expect(page).to have_css(".parsons-status", text: "position 2 of 3", visible: :all)
      expect(hidden_answer).to eq("order:0,2,1")
    end
  end

  it "moves focus between blocks with a bare arrow key" do
    travel_to(weekday) do
      visit_seeded_dashboard(cdn: :loaded)

      find("ol[data-parsons-blocks] .parsons-block", match: :first).send_keys(:down)

      expect(block_ids).to eq([ "2", "0", "1" ])
      expect(page.evaluate_script("document.activeElement.dataset.blockId")).to eq("0")
    end
  end
end
