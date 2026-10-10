require "rails_helper"

RSpec.describe "Leaving the learning track", type: :system do
  let(:user) { create_fake_provider_user }

  around { |example| travel_to(a_weekday + 12.hours) { example.run } }

  before do
    user.update!(learning_track: "junior", section_kind_levels: LearningTrack.preset_levels)
    visit_as(user)
    visit setup_path
    find("#exercise-mix summary").click
    page.execute_script("window.trackSetupPage = true")
  end

  def expect_same_page
    expect(page).to have_current_path(setup_path)
    expect(page.evaluate_script("window.trackSetupPage")).to be(true)
    expect(find("#exercise-mix")).to match_css("[open]")
  end

  it "keeps an Exercise mix edit made just before leaving the track" do
    # One browser turn puts Leave inside the real debounce, before a driver round trip lets the mix save finish.
    page.execute_script(<<~JS)
      const slider = document.querySelector("#weight-challenge");
      slider.value = 0;
      slider.dispatchEvent(new Event("input"));
      document.querySelector("#leave-learning-track").click();
    JS
    page.driver.with_playwright_page do |pw|
      pw.wait_for_function("window.trackSetupPage === undefined || !window.CodeGymSaveStatus.pending()")
    end

    aggregate_failures do
      expect_same_page
      expect(page).to have_css("#learning-track", text: "You've left the junior track")
      expect(user.reload.learning_track).to eq("none")
      expect(user.section_kind_weights).to eq("challenge" => 0.25)
      expect(user.section_kind_levels).to eq(LearningTrack.preset_levels)
    end
  end

  def focused(attribute)
    page.evaluate_script("document.activeElement.getAttribute(#{attribute.to_json})")
  end

  # The confirmation takes focus because the button that had it is removed.
  it "removes the key guide and moves focus to an announced confirmation" do
    expect(page).to have_css(".key-guide")

    click_button "Leave the track"

    expect(page).to have_css("#learning-track [role='status']", text: "You've left the junior track")
    expect(page).not_to have_css(".key-guide")
    expect(focused("role")).to eq("status")
    expect(page.evaluate_script("document.activeElement.textContent")).to include("You've left the junior track")
    expect_same_page
  end

  it "reports a failed leave without navigating or changing stored settings" do
    page.execute_script("window.fetch = () => Promise.reject(new Error('offline'))")

    click_button "Leave the track"

    expect(page).to have_css("#save-status", text: /couldn't save/i)
    expect(page).to have_button("Leave the track", disabled: false)
    expect_same_page
    expect(user.reload.learning_track).to eq("junior")
    expect(user.section_kind_weights).to eq({})
    expect(user.section_kind_levels).to eq(LearningTrack.preset_levels)
  end

  it "keeps a failed mix save visible after successfully leaving the track" do
    page.execute_script(<<~JS)
      const originalFetch = window.fetch;
      window.fetch = (url, options) => {
        if (url.endsWith("/profile") && JSON.parse(options.body).user.section_kind_weights) {
          return Promise.reject(new Error("offline"));
        }
        return originalFetch(url, options);
      };
    JS
    find("#weight-challenge").set(0)
    expect(page).to have_css("#save-status", text: /couldn't save/i)

    click_button "Leave the track"

    expect(page).to have_css("#learning-track", text: "You've left the junior track")
    expect(page).to have_css("#save-status", text: /couldn't save/i)
    expect_same_page
    expect(find("#weight-label-challenge")).to have_text("Much less")
    expect(user.reload.learning_track).to eq("none")
    expect(user.section_kind_weights).to eq({})
    expect(user.section_kind_levels).to eq(LearningTrack.preset_levels)
  end
end
