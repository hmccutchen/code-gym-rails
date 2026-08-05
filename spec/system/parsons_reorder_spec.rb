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

  def block_ids
    all("ol[data-parsons-blocks] .parsons-block").map { |li| li["data-block-id"] }
  end

  def hidden_answer
    find("textarea[data-field='parsons_problem']", visible: :all).value
  end

  # data-sortable-done is set by the SortableJS module once drag is wired, so
  # waiting on it is what makes the assertions meaningful rather than merely early.
  def visit_seeded_dashboard
    seed_parsons_exercise
    visit_as(user)
    expect(page).to have_css("ol[data-parsons-blocks][data-sortable-done]", wait: 10)
  end

  it "shows no arrow buttons once drag is available" do
    travel_to(weekday) do
      visit_seeded_dashboard

      expect(page).to have_no_css(".parsons-move-up")
      expect(page).to have_no_css(".parsons-move-down")
    end
  end

  it "reorders with the keyboard, since dragging is pointer-only" do
    travel_to(weekday) do
      visit_seeded_dashboard
      expect(block_ids).to eq([ "2", "0", "1" ])

      find("ol[data-parsons-blocks] .parsons-block", match: :first).send_keys(%i[control down])

      expect(block_ids).to eq([ "0", "2", "1" ])
      expect(page).to have_css(".parsons-status", text: "position 2 of 3", visible: :all)
      expect(hidden_answer).to eq("order:0,2,1")
    end
  end

  it "moves focus between blocks with a bare arrow key" do
    travel_to(weekday) do
      visit_seeded_dashboard

      find("ol[data-parsons-blocks] .parsons-block", match: :first).send_keys(:down)

      expect(block_ids).to eq([ "2", "0", "1" ])
      expect(page.evaluate_script("document.activeElement.dataset.blockId")).to eq("0")
    end
  end
end
