require "rails_helper"

RSpec.describe "A bug_hunt code review on a phone", type: :system do
  let(:hunt) do
    { "question" => "What's wrong, why, and how would you fix it?", "purpose" => "Remove every even number from nums.",
      "snippet" => "def remove_evens(nums)\n  nums.each { |n| nums.delete(n) if n.even? }\n  nums\nend",
      "concept" => "array_mutation_pitfalls", "pitched_at" => "junior" }
  end

  def open_dashboard(user)
    resize(320)
    visit_with_todays_set(user)
    exercise = DailyExercise.find_by!(user: user, date: Date.current)
    exercise.update!(problem_set: exercise.problem_set.merge("code_review" => hunt))
    visit root_path
    wait_for_js
  end

  def code_review = find("details.section[data-section-fold='code_review']")

  it "shows the goal line and numbered lines, names no concept, and keeps the page from scrolling sideways" do
    travel_to(a_weekday) do
      open_dashboard(create_fake_provider_user)

      expect(code_review).to have_css(".bug-hunt-goal", text: "Goal: Remove every even number from nums.")
      expect(code_review).to have_css("pre.snippet code.numbered .code-line", count: 4)
      expect(code_review).to have_no_text("Array mutation pitfalls")
      expect(sideways_overflow).to eq(0)
    end
  end
end
