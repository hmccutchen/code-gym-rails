require "rails_helper"

RSpec.describe "Parsons reorder controls", type: :system do
  it "shows no arrow buttons once drag is available" do
    user = create_fake_provider_user
    weekday = a_weekday

    travel_to(weekday) do
      # Pre-seed today's exercise with parsons_problem as the third section so
      # the dashboard renders it immediately without running a generation job.
      # FakeService always loses parsons_problem to architecture in DailyPlan's
      # precedence order, so relying on generation would never produce this section.
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

      visit_as(user)

      expect(page).to have_css("ol[data-parsons-blocks]", wait: 10)

      # data-sortable-done is set by the SortableJS module once drag is wired,
      # so waiting on it is what makes the absence assertion below meaningful
      # rather than merely early.
      expect(page).to have_css("ol[data-parsons-blocks][data-sortable-done]", wait: 10)
      expect(page).to have_no_css(".parsons-move-up")
      expect(page).to have_no_css(".parsons-move-down")
    end
  end
end
