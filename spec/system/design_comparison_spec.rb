require "rails_helper"

# The pick and reason write one stored answer through an inline script, which only a real browser runs.
RSpec.describe "Answering a design comparison on a phone", type: :system do
  let(:reason) { "A new carrier is added every month, so the registry means no edit to working code." }

  def resize(width)
    page.driver.with_playwright_page { |pw| pw.set_viewport_size(width: width, height: 844) }
  end

  def comparison
    find("[data-comparison-answer='design_comparison']")
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
        fill_in("What decides it?", with: "Too short")
      end
      expect(hidden_answer["data-answer-complete"]).to eq("false")
      expect(page).to have_css(".section-status[data-status-for='design_comparison']", text: "", exact_text: true)

      within(comparison) { fill_in("What decides it?", with: reason) }
      expect(hidden_answer["data-answer-complete"]).to eq("true")
      expect(hidden_answer.value).to eq("pick:b\n#{reason}")

      rate_section("design_comparison")
      expect(page).to have_button("Submit answers", disabled: false)

      Timeout.timeout(10) do
        sleep 0.05 until user.daily_responses.reload.first&.answered?("design_comparison")
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
      Timeout.timeout(10) do
        sleep 0.05 until user.daily_responses.reload.sole.answers["code_review"].present?
      end

      expect(ExerciseSection::DesignComparison.parse_answer(user.daily_responses.sole.answers["design_comparison"]))
        .to eq([ nil, reason ])
    end
  end

  # The server counts code points, so the browser must too: an emoji is one code point but two UTF-16 units.
  it "marks a reason complete at the same length the server does, counting code points" do
    travel_to(a_weekday) do
      user = create_fake_provider_user
      visit_with_todays_set(user)
      floor = ExerciseSection::DesignComparison::MIN_REASON_LENGTH

      within(comparison) do
        choose("Piece A")
        fill_in("What decides it?", with: "\u{1F600}" * (floor - 1))
      end
      expect(hidden_answer["data-answer-complete"]).to eq("false")
      expect(ExerciseSection::DesignComparison.answered?(hidden_answer.value)).to be(false)

      within(comparison) { fill_in("What decides it?", with: "\u{1F600}" * floor) }
      expect(hidden_answer["data-answer-complete"]).to eq("true")
      expect(ExerciseSection::DesignComparison.answered?(hidden_answer.value)).to be(true)
    end
  end
end
