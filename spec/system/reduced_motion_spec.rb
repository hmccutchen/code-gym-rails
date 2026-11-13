require "rails_helper"

# Chromium honours an emulated prefers-reduced-motion, so these read the styles that OS setting produces.
RSpec.describe "Reduced motion", type: :system do
  let(:user) { create_fake_provider_user }

  def prefer_reduced_motion(value = "reduce")
    page.driver.with_playwright_page { |pw| pw.emulate_media(reducedMotion: value) }
  end

  def add_motion_elements
    page.execute_script(<<~JS)
      document.body.insertAdjacentHTML("beforeend",
        '<span class="spinner" id="t-spinner"></span>' +
        '<button class="btn btn-loading" id="t-loading">Working</button>' +
        '<div class="pull-refresh is-refreshing is-settling" id="t-pull"><span class="spinner"></span></div>' +
        '<div class="pull-settling" id="t-content"></div>');
    JS
  end

  def computed(script)
    page.evaluate_script(script)
  end

  it "stops the spinners and the pull-to-refresh settle, indicator and page content, when the OS asks for less motion" do
    prefer_reduced_motion
    visit_as(user)
    visit learn_path
    add_motion_elements

    expect(computed("getComputedStyle(document.getElementById('t-spinner')).animationName")).to eq("none")
    expect(computed("getComputedStyle(document.getElementById('t-loading'), '::before').animationName")).to eq("none")
    expect(computed("getComputedStyle(document.querySelector('#t-pull .spinner')).animationName")).to eq("none")
    expect(computed("getComputedStyle(document.getElementById('t-pull')).transitionDuration")).to eq("0s")
    expect(computed("getComputedStyle(document.getElementById('t-content')).transitionDuration")).to eq("0s")
  end

  it "leaves the motion in place otherwise" do
    prefer_reduced_motion("no-preference")
    visit_as(user)
    visit learn_path
    add_motion_elements

    expect(computed("getComputedStyle(document.getElementById('t-spinner')).animationName")).to eq("spin")
    expect(computed("getComputedStyle(document.getElementById('t-loading'), '::before').animationName")).to eq("spin")
    expect(computed("getComputedStyle(document.querySelector('#t-pull .spinner')).animationName")).to eq("spin")
    expect(computed("getComputedStyle(document.getElementById('t-pull')).transitionDuration")).not_to eq("0s")
    expect(computed("getComputedStyle(document.getElementById('t-content')).transitionDuration")).not_to eq("0s")
  end

  it "fills the dashboard progress bar without sliding" do
    travel_to(a_weekday) do
      prefer_reduced_motion
      visit_with_todays_set(user)

      expect(computed("getComputedStyle(document.querySelector('.progress-fill')).transitionDuration")).to eq("0s")
    end
  end

  def sheet_animation_name
    travel_to(a_weekday + 12.hours) do
      visit_with_todays_set(user)
      within("#daily-kind-swap-panel-1") { find("button.daily-kind-trigger").click }
      expect(page).to have_css("#daily-kind-1-sheet[open]")
      computed("getComputedStyle(document.getElementById('daily-kind-1-sheet')).animationName")
    end
  end

  it "slides the daily kind sheet open only when the OS allows motion" do
    prefer_reduced_motion("no-preference")
    expect(sheet_animation_name).not_to eq("none")
  end

  it "opens the daily kind sheet without sliding when the OS asks for less motion" do
    prefer_reduced_motion
    expect(sheet_animation_name).to eq("none")
  end
end
