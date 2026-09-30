require "rails_helper"

RSpec.describe "Leaving the learning track on Setup", type: :system, with_csrf: true do
  let(:user) do
    create_fake_provider_user.tap do |user|
      user.update!(learning_track: "junior", section_kind_levels: LearningTrack.preset_levels,
                   locked_section_kinds: [ "pattern" ], excluded_section_kinds: [ "parsons_problem" ],
                   paused_generation_at: Time.current)
    end
  end

  def open_setup
    visit_as(user)
    visit setup_path
    page.execute_script("window.taskSixPage = true")
  end

  def guide_measurement
    page.evaluate_script(<<~JS)
      (() => {
        const guide = document.querySelector(".key-guide");
        const rect = guide.getBoundingClientRect();
        const style = getComputedStyle(guide.querySelector(".hint"));
        const nav = document.querySelector("nav");
        return { width: innerWidth, viewportHeight: innerHeight,
          guideWidth: rect.width, guideHeight: rect.height, guideTop: rect.top, guideBottom: rect.bottom,
          fontSize: style.fontSize, lineHeight: style.lineHeight, paragraphMargin: style.marginBottom,
          navHeight: nav.getBoundingClientRect().height, navPosition: getComputedStyle(nav).position,
          documentWidth: document.documentElement.scrollWidth };
      })()
    JS
  end

  it "leaves in place while a debounced exercise-mix edit finishes" do
    open_setup
    expect(page).to have_button("Leave the track")
    find("#exercise-mix summary").click
    page.execute_script(<<~JS)
      const slider = document.getElementById("weight-challenge");
      slider.value = "0";
      slider.dispatchEvent(new Event("input", { bubbles: true }));
      document.getElementById("leave-learning-track").click();
    JS

    expect(page).to have_css("#learning-track", text: "You've left the junior track. Your difficulty settings stay as they are.")
    expect(page).to have_no_button("Leave the track")
    Timeout.timeout(5) { sleep 0.05 until user.reload.section_kind_weights == { "challenge" => 0.25 } }
    expect(user.reload.learning_track).to eq("none")
    expect(user.section_kind_levels).to eq(LearningTrack.preset_levels)
    expect(user.locked_section_kinds).to eq([ "pattern" ])
    expect(user.excluded_section_kinds).to eq([ "parsons_problem" ])
    expect(page.evaluate_script("window.taskSixPage")).to be(true)
    expect(page).to have_no_css("#save-status", visible: true)
  end

  it "lets queued mix saves finish behind an in-flight save after leaving" do
    open_setup
    find("#exercise-mix summary").click
    page.execute_script(<<~JS)
      const original = window.fetch;
      window.fetch = function (url, options) {
        const response = original.apply(this, arguments);
        if (String(url).includes("/profile") && JSON.parse(options.body).user.section_kind_weights) {
          window.fetch = original;
          return response.then(result => new Promise(resolve => {
            window.releaseFirstMix = () => resolve(result);
          }));
        }
        return response;
      };
    JS
    find("#weight-challenge").set(0)
    Timeout.timeout(5) { sleep 0.05 until page.evaluate_script("!!window.releaseFirstMix") }
    find("#weight-challenge").set(4)
    sleep 0.6 # The second save must pass the 400ms debounce and queue behind the first.
    click_button "Leave the track"
    expect(page).to have_css("#learning-track", text: "You've left the junior track")

    page.execute_script("window.releaseFirstMix()")
    Timeout.timeout(5) { sleep 0.05 until user.reload.section_kind_weights == { "challenge" => 4.0 } }
    expect(user.reload.learning_track).to eq("none")
    expect(page.evaluate_script("window.taskSixPage")).to be(true)
    expect(page).to have_no_css("#save-status", visible: true)
  end

  it "keeps a refused save visible and allows retrying the leave control" do
    open_setup
    page.execute_script(<<~JS)
      const original = window.fetch;
      window.fetch = function (url, options) {
        if (String(url).includes("/profile") && JSON.parse(options.body).user.learning_track) {
          window.fetch = original;
          return Promise.resolve(new Response(JSON.stringify({ errors: ["Leave was refused"] }),
            { status: 422, headers: { "Content-Type": "application/json" } }));
        }
        return original.apply(this, arguments);
      };
    JS
    click_button "Leave the track"

    expect(page).to have_css("#save-status", text: "Leave was refused")
    expect(page).to have_button("Leave the track", disabled: false)
    expect(user.reload.learning_track).to eq("junior")
    expect(page.evaluate_script("window.taskSixPage")).to be(true)

    click_button "Leave the track"
    expect(page).to have_css("#learning-track", text: "You've left the junior track")
    expect(user.reload.learning_track).to eq("none")
  end

  it "preserves an unrelated save failure when leaving succeeds" do
    open_setup
    page.execute_script(<<~JS)
      const original = window.fetch;
      window.fetch = function (url, options) {
        if (String(url).includes("/profile") && JSON.parse(options.body).user.section_kind_weights) {
          return Promise.resolve(new Response(JSON.stringify({ errors: ["Mix was refused"] }),
            { status: 422, headers: { "Content-Type": "application/json" } }));
        }
        return original.apply(this, arguments);
      };
    JS
    find("#exercise-mix summary").click
    find("#weight-challenge").set(0)
    expect(page).to have_css("#save-status", text: "Mix was refused")
    click_button "Leave the track"

    expect(page).to have_css("#learning-track", text: "You've left the junior track")
    expect(page).to have_css("#save-status", text: "Mix was refused")
    expect(page.evaluate_script("window.taskSixPage")).to be(true)
  end

  it "measures the approved guide at phone width without hiding content or shrinking type" do
    page.driver.with_playwright_page { |pw| pw.set_viewport_size(width: 390, height: 844) }
    open_setup
    expect(page).to have_css(".key-guide")

    [ "100", "125", "140" ].each do |size|
      user.update!(display_preferences: size == "100" ? {} : { "text_size" => size })
      visit setup_path
      measurement = guide_measurement
      puts "Task 6 key guide at #{size}%: #{measurement.to_json}"
      expect(measurement["documentWidth"]).to be <= 390
      expect(measurement["fontSize"].to_f).to be >= 12.8
      expect(page).to have_css(".key-guide li", count: 8)
      expect(page).to have_css(".key-guide p", text: "What it costs.")
    end
  end
end
