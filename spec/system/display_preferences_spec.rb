require "rails_helper"

# The Display controls on Setup: each choice applies to the page at once,
# saves, and is still there after a reload. The request specs cover what the
# layout renders from a stored choice; these cover the browser's side.
RSpec.describe "Display preferences", type: :system, with_csrf: true do
  let(:user) { create_fake_provider_user(daily_section_count: ExerciseSection::MAX_SECTIONS) }

  def open_display
    visit_as(user)
    visit setup_path
    find("#display-preferences summary").click
  end

  def choose_display(setting, value)
    find(%(#display-preferences input[data-setting="#{setting}"][value="#{value}"])).click
  end

  def html_attribute(name)
    page.evaluate_script("document.documentElement.getAttribute(#{name.to_json})")
  end

  def expect_pattern(tile, tint)
    values = page.evaluate_script(<<~JS)
      (() => {
        const s = getComputedStyle(document.getElementById("background-pattern"));
        return [s.maskImage, s.webkitMaskImage, s.backgroundColor];
      })()
    JS
    expect(values.first).to match(%r{/#{Regexp.escape(tile)}-[a-f0-9]+\.png})
    expect(values[1]).to eq(values.first)
    expect(values.last).to eq(tint)
  end

  def stored(timeout: 5)
    deadline = Time.current + timeout
    sleep 0.1 until yield(user.reload.display_preferences) || Time.current > deadline
    user.reload.display_preferences
  end

  it "removes the pattern immediately and can restore it from an initially off page" do
    open_display
    expect(page).to have_css("#background-pattern", visible: :all)
    choose_display("background_pattern", "off")
    expect(page).to have_no_css("#background-pattern", visible: :all)
    expect(stored { |values| values["background_pattern"] == "off" }).to eq("background_pattern" => "off")

    visit setup_path
    expect(page).to have_no_css("#background-pattern", visible: :all)
    find("#display-preferences summary").click
    choose_display("background_pattern", "on")
    expect(page).to have_css("body > #background-pattern[aria-hidden='true']", visible: :all)
    expect(stored(&:empty?)).to eq({})
    visit history_path
    expect(page).to have_css("#background-pattern", visible: :all)
  end

  it "keeps the mask fixed, repeated and below the refresh indicator without intercepting input" do
    open_display
    properties = page.evaluate_script(<<~JS)
      (() => {
        const s = getComputedStyle(document.getElementById("background-pattern"));
        return [s.position, s.pointerEvents, s.zIndex, s.maskSize, s.maskRepeat, s.imageRendering, s.maskImage];
      })()
    JS
    expect(properties.first(6)).to eq([ "fixed", "none", "-2", "288px", "repeat", "pixelated" ])
    expect(properties.last).to include("gym-pattern-tile-")
    page.execute_script("window.scrollTo(0, 400)")
    expect(page.evaluate_script("document.getElementById('background-pattern').getBoundingClientRect().top")).to eq(0)
    expect(page.evaluate_script("document.getElementById('background-pattern').closest('[data-pull-content]') === null")).to be(true)
  end

  it "hides the pattern when the device asks for more contrast or forced colors" do
    open_display
    page.driver.with_playwright_page do |pw|
      pw.emulate_media(contrast: "more")
      expect(page.evaluate_script("getComputedStyle(document.getElementById('background-pattern')).display")).to eq("none")
      pw.emulate_media(contrast: "no-preference", forcedColors: "active")
      expect(page.evaluate_script("getComputedStyle(document.getElementById('background-pattern')).display")).to eq("none")
      pw.emulate_media(forcedColors: "none")
      expect(page.evaluate_script("getComputedStyle(document.getElementById('background-pattern')).display")).to eq("block")
    end
  end

  it "switches the mask and tint with the chosen theme, including live device changes" do
    open_display
    expect_pattern("gym-pattern-tile-dark", "rgb(190, 205, 240)")
    choose_display("theme", "light")
    expect_pattern("gym-pattern-tile", "rgb(52, 97, 154)")
    choose_display("theme", "dark")
    expect_pattern("gym-pattern-tile-dark", "rgb(190, 205, 240)")

    choose_display("theme", "device")
    page.driver.with_playwright_page do |pw|
      pw.emulate_media(colorScheme: "light")
      expect_pattern("gym-pattern-tile", "rgb(52, 97, 154)")
      pw.emulate_media(colorScheme: "dark")
      expect_pattern("gym-pattern-tile-dark", "rgb(190, 205, 240)")
    end
    expect(stored { |values| values["theme"] == "device" }).to eq("theme" => "device")
    visit history_path
    expect_pattern("gym-pattern-tile-dark", "rgb(190, 205, 240)")
  end

  it "follows the device's mask and tint on a signed-out page" do
    visit login_path
    page.driver.with_playwright_page do |pw|
      pw.emulate_media(colorScheme: "light")
      expect_pattern("gym-pattern-tile", "rgb(52, 97, 154)")
      pw.emulate_media(colorScheme: "dark")
      expect_pattern("gym-pattern-tile-dark", "rgb(190, 205, 240)")
    end
  end

  it "applies each choice at once, saves it, and keeps it after a reload" do
    open_display

    choose_display("theme", "light")
    choose_display("text_size", "125")
    choose_display("line_spacing", "loose")
    choose_display("font", "atkinson")

    expect(html_attribute("data-theme")).to eq("light")
    expect(page.evaluate_script(%(document.querySelector('meta[name="theme-color"]').media))).to eq("all")
    expect(html_attribute("data-text-size")).to eq("125")
    expect(page.evaluate_script("getComputedStyle(document.body).backgroundColor")).to eq("rgb(245, 245, 250)")

    expected = { "theme" => "light", "text_size" => "125", "line_spacing" => "loose", "font" => "atkinson" }
    expect(stored { |values| values == expected }).to eq(expected)

    visit setup_path
    expect(html_attribute("data-line-spacing")).to eq("loose")
    expect(html_attribute("data-font")).to eq("atkinson")
    expect(find(%(input[data-setting="text_size"][value="125"]), visible: :all)).to be_checked

    find("#display-preferences summary").click
    choose_display("text_size", "100")
    expect(page.evaluate_script("document.documentElement.hasAttribute('data-text-size')")).to be(false)
    expect(stored { |values| !values.key?("text_size") }).not_to have_key("text_size")
  end

  it "shows the plain logo on the light theme and the outlined one on dark" do
    open_display
    logo = -> { page.evaluate_script("document.querySelector('nav .brand-mark').currentSrc") }

    expect(logo.call).to include("logo-outlined")

    choose_display("theme", "light")
    expect(page).to have_css("nav .brand-mark")
    # currentSrc reads empty while the new source loads, so wait for the plain
    # logo itself rather than for the outlined one to go.
    plain_logo = %r{/logo-[0-9a-f]+\.png}
    Timeout.timeout(5) { sleep 0.05 until logo.call.match?(plain_logo) }
    expect(logo.call).to match(plain_logo)

    choose_display("theme", "dark")
    Timeout.timeout(5) { sleep 0.05 until logo.call.include?("outlined") }
  end

  it "stores the later of two quick choices even when the first save is slow to leave" do
    open_display
    page.execute_script(<<~JS)
      (function () {
        const original = window.fetch;
        let first = true;
        window.fetch = function (url, options) {
          if (String(url).indexOf("/profile") === -1 || !first) return original.apply(this, arguments);
          first = false;
          const args = arguments;
          return new Promise((resolve) => setTimeout(resolve, 800)).then(() => original.apply(this, args));
        };
      })();
    JS

    choose_display("theme", "light")
    choose_display("theme", "device")

    sleep 1.5
    expect(stored { |values| values["theme"] == "device" }).to eq("theme" => "device")
  end

  it "keeps code in its monospace font under a reading font" do
    user.update!(display_preferences: { "font" => "atkinson" })

    travel_to(a_weekday) do
      visit_with_todays_set(user)
      expect(page).to have_css("pre.snippet", wait: 10)

      family = ->(selector) { page.evaluate_script("getComputedStyle(document.querySelector(#{selector.to_json})).fontFamily") }
      expect(family.call(".question")).to include("Atkinson Hyperlegible")
      expect(family.call("pre.snippet")).to eq("monospace, monospace")
      expect(family.call("pre.snippet code")).to eq("monospace, monospace")
      expect(family.call("textarea.code-answer")).to include("Fira Code")
    end
  end

  it "fits a phone screen at the largest text size, with the sticky bar unclipped" do
    user.update!(display_preferences: { "text_size" => "140" })
    page.driver.with_playwright_page { |pw| pw.set_viewport_size(width: 390, height: 844) }

    travel_to(a_weekday) do
      visit_with_todays_set(user)
      expect(page).to have_css(".progress-sticky", wait: 10)

      sticky = page.evaluate_script("(() => { const s = document.querySelector('.progress-sticky'); return [s.scrollHeight, s.clientHeight]; })()")
      expect(sticky.first).to be <= sticky.last

      [ root_path, history_path, learn_path, progress_path, setup_path, account_path ].each do |path|
        visit path
        expect(page.evaluate_script("document.documentElement.scrollWidth")).to be <= 390, "#{path} scrolls sideways"
      end
    end
  end
end
