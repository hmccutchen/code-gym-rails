require "rails_helper"

# The pick and reason write one stored answer through a Stimulus controller, which only a real browser runs.
RSpec.describe "Answering a design comparison on a phone", type: :system do
  let(:reason) { "A new carrier is added every month, so the registry means no edit to working code." }

  def resize(width)
    page.driver.with_playwright_page { |pw| pw.set_viewport_size(width: width, height: 844) }
  end

  def comparison
    find("[data-comparison-answer='design_comparison']")
  end

  # The status line is uppercased by CSS, and Playwright matches the rendered text.
  def in_progress = /#{I18n.t("responses.section_status.in_progress")}/i

  def wait_for_saved_comparison(user, answer)
    wait_for { user.daily_responses.reload.first&.answers&.dig("design_comparison") == answer }
  end

  def hidden_answer
    find("textarea[data-field='design_comparison']", visible: :all)
  end

  it "fits 390px, gives each control a 44px target, and saves the pick and reason as one answer" do
    travel_to(a_weekday) do
      user = create_fake_provider_user
      resize(390)
      visit_with_todays_set(user)

      expect(page.evaluate_script("document.documentElement.scrollWidth")).to eq(390)
      heights = page.evaluate_script(<<~JS)
        [...document.querySelectorAll("details.comparison-piece > summary, .comparison-pick label")]
          .map(el => el.getBoundingClientRect().height)
      JS
      expect(heights.size).to eq(4)
      expect(heights).to all(be >= 44)

      within(comparison) do
        expect(page).to have_css("legend", text: "Which piece fits this system better?")
        choose("Piece B")
      end
      wait_for_saved_comparison(user, "pick:b\n")
      expect(page).to have_css(".section-status[data-status-for='design_comparison']", text: "", exact_text: true)

      within(comparison) { fill_in("What decides it?", with: "Retries") }
      expect(page).to have_css(".section-status[data-status-for='design_comparison']", text: in_progress)

      within(comparison) { fill_in("What decides it?", with: reason) }
      expect(hidden_answer.value).to eq("pick:b\n#{reason}")

      rate_section("design_comparison")
      expect(page).to have_selector("#rating-nudge", visible: :hidden)

      wait_for do
        user.daily_responses.reload.first&.answered?("design_comparison")
      end
      expect(user.daily_responses.sole.answers["design_comparison"]).to eq("pick:b\n#{reason}")

      visit root_path
      within(comparison) do
        expect(find_field("Piece B")).to be_checked
        expect(find_field("What decides it?").value).to eq(reason)
      end
    end
  end

  # HTML drops a newline right after <textarea>, which once let a pick-less reason be re-saved as the pick line.
  it "keeps a reason saved without a pick through a reload and another section's autosave" do
    travel_to(a_weekday) do
      user = create_fake_provider_user
      perform_enqueued_jobs { GenerateDailyExercisesJob.perform_now(user_id: user.id) }
      exercise = DailyExercise.find_by!(user: user, date: Date.current)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "design_comparison" => "\n#{reason}" })
      visit_as(user)

      expect(hidden_answer.value).to eq("\n#{reason}")
      within(comparison) { expect(find_field("What decides it?").value).to eq(reason) }

      find("textarea[data-field='code_review']").fill_in(with: "An answer to the code review that is long enough.")
      wait_for do
        user.daily_responses.reload.sole.answers["code_review"].present?
      end

      expect(ExerciseSection::DesignComparison.parse_answer(user.daily_responses.sole.answers["design_comparison"]))
        .to eq([ nil, reason ])
    end
  end
end
