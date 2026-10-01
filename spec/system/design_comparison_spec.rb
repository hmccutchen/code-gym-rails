require "rails_helper"

# The pick and the reason are two controls writing one stored answer through
# an inline script, which only a real browser runs.
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
end
