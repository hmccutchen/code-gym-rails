require "rails_helper"

RSpec.describe "Today's desktop layout", type: :system do
  around { |example| travel_to(a_weekday) { example.run } }

  def visit_today(width:, height: 900, prefs: {})
    resize(width, height: height)
    @user = create_fake_provider_user(daily_section_count: ExerciseSection::MAX_SECTIONS)
    @user.update!(display_preferences: prefs)
    visit_with_todays_set(@user)
  end

  def submit_the_day
    fill_in_answer("code_review", "It re-runs the query inside the loop; load it once before.")
    rate_section("code_review")
    click_button "Submit answers"
    expect(page).to have_css("#ai-review")
  end

  def main = rect(".today-main")

  def side = rect(".today-side")

  # One call, in page coordinates, so a scroll between measurements can't move them.
  def layout_facts
    page.evaluate_script(<<~JS)
      Object.fromEntries([["main", ".today-main"], ["side", ".today-side"], ["submit", "#submit-answers"],
                          ["nudge", "#rating-nudge"], ["regenerate", ".regenerate-row"]].map(([name, selector]) => {
        const r = document.querySelector(selector).getBoundingClientRect();
        return [name, [r.left + scrollX, r.top + scrollY, r.width, r.height]];
      }))
    JS
  end

  def expect_same_layout(before, after)
    before.each { |name, box| expect(after[name]).to eq(box), "#{name} moved from #{box} to #{after[name]}" }
  end

  def content_width = container_content.then { |content| content["right"] - content["left"] }

  describe "sideways scroll" do
    LayoutHelpers::LAYOUT_WIDTHS.each do |width|
      [ {}, LayoutHelpers::LARGEST_TEXT ].each do |prefs|
        it "keeps an open and a submitted day inside a #{width}px window#{' with the largest text' if prefs.any?}" do
          visit_today(width: width, prefs: prefs)
          expect(sideways_overflow).to eq(0)
          submit_the_day
          expect(sideways_overflow).to eq(0)
        end
      end
    end
  end

  describe "the desktop rules" do
    [ 390, 768, 899 ].each do |width|
      it "change nothing at #{width}px" do
        visit_today(width: width)
        expect_same_layout(without_desktop_rules { layout_facts }, layout_facts)
      end
    end

    it "take effect at 900px" do
      visit_today(width: 900)
      expect(without_desktop_rules { layout_facts }).not_to eq(layout_facts)
    end
  end

  it "keeps the gap before Submit at one section margin between 600 and 899px" do
    visit_today(width: 768)

    expect(rect("#submit-row")["top"] - rects(".today-main .section").last["bottom"]).to be_within(0.5).of(24)
  end

  it "ends the page with Submit and then the regenerate row on a phone" do
    visit_today(width: 390, height: 844)

    expect(rect("#submit-row")["top"]).to be > rects(".today-main .section").last["bottom"]
    expect(rect(".regenerate-row")["top"]).to be > rect("#submit-row")["bottom"]
  end

  describe "on a desktop" do
    [ 900, 1280, 1920 ].each do |width|
      it "puts a 280px side column beside the answers at #{width}px" do
        visit_today(width: width)
        full = [ 1040, width - 48 ].min

        expect(content_width).to be_within(0.5).of(full)
        expect(side["width"]).to be_within(0.5).of(280)
        expect(side["left"] - main["right"]).to be_within(0.5).of(24)
        expect(side["top"]).to be_within(0.5).of(main["top"])
        expect(main["width"]).to be_within(0.5).of(full - 280 - 24)
        submit = rect("#submit-answers")
        expect(submit["top"]).to be < main["top"] + 200
        expect(submit["height"]).to be >= 48
        expect(rects(".today-side .regenerate-row .btn").map { |r| r["height"] }).to all(be >= 44)
      end
    end

    it "keeps Submit after the last answer control in tab order" do
      visit_today(width: 1280)

      expect(page.evaluate_script(<<~JS)).to be(true)
        (() => {
          const last = [...document.querySelectorAll("#gym-form .rating-btn")].pop();
          return Boolean(last.compareDocumentPosition(document.getElementById("submit-answers")) & Node.DOCUMENT_POSITION_FOLLOWING);
        })()
      JS
    end

    it "keeps the side column in view while the answers scroll in a window at least 640px tall" do
      visit_today(width: 1280, height: 640)
      page.execute_script("window.scrollTo(0, 1200)")

      expect(side["top"]).to be_within(0.5).of(24)
    end

    it "lets the side column scroll away in a shorter window" do
      visit_today(width: 1280, height: 639)
      page.execute_script("window.scrollTo(0, 1200)")

      expect(side["bottom"]).to be < 0
    end

    it "shows a held submit's notice in the main column, on screen" do
      visit_today(width: 1280)
      page.execute_script(<<~JS)
        const originalFetch = window.fetch;
        window.fetch = (url, options) => {
          const body = options?.body ? JSON.parse(options.body) : {};
          if (!body.response || body.response.submit === "1") return originalFetch(url, options);
          return new Promise(() => {});
        };
      JS
      fill_in_answer("code_review", "The answer an autosave is still carrying when the submit goes out.")
      rate_section("code_review")
      click_button "Submit answers"

      expect(page).to have_css(".today-main #leave-held")
      notice = rect("#leave-held")
      expect(notice["top"]).to be >= 0
      # Scroll positions snap to whole pixels, so allow a sub-pixel overlap.
      expect(notice["bottom"]).to be <= page.evaluate_script("window.innerHeight") + 0.5
    end

    it "keeps the side column on a submitted day, holding the regenerate row" do
      visit_today(width: 1280)
      submit_the_day
      page.execute_script("window.scrollTo(0, 0)")

      expect(side["width"]).to be_within(0.5).of(280)
      expect(side["top"]).to be_within(0.5).of(main["top"])
      expect(page).to have_css(".today-side .regenerate-row")
    end
  end
end
