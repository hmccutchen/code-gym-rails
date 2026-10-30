require "rails_helper"

RSpec.describe "Today's phone layout", type: :system do
  around { |example| travel_to(a_weekday) { example.run } }

  def visit_today(width: 390, height: 844, prefs: {}, user: create_fake_provider_user(daily_section_count: ExerciseSection::MAX_SECTIONS))
    resize(width, height: height)
    user.update!(display_preferences: prefs)
    visit_with_todays_set(user)
  end

  # Playwright can't emulate display-mode, so the layout's standalone rule is switched on through the CSSOM.
  def force_standalone
    page.execute_script(<<~JS)
      for (const sheet of document.styleSheets) {
        for (const rule of sheet.cssRules) {
          if (rule instanceof CSSMediaRule && rule.media.mediaText === "(display-mode: standalone)") rule.media.mediaText = "all";
        }
      }
    JS
  end

  def window_height = page.evaluate_script("window.innerHeight")

  def cards = rects(".today-page .section")

  def submit_row = rect("#submit-row")

  def row_position = computed_style("#submit-row", "position")

  describe "the section cards" do
    [ 320, 390 ].each do |width|
      [ {}, LayoutHelpers::LARGEST_TEXT ].each do |prefs|
        it "runs each section as a full-width card, 16px apart, at #{width}px#{' with the largest text' if prefs.any?}" do
          visit_today(width: width, prefs: prefs)

          expect(cards.size).to eq(ExerciseSection::MAX_SECTIONS)
          edges(".today-page .section").each do |left, right|
            expect(left).to be_within(0.5).of(0)
            expect(right).to be_within(0.5).of(0)
          end
          cards.each_cons(2) { |upper, lower| expect(lower["top"] - upper["bottom"]).to be_within(0.5).of(16) }
          expect(computed_style(".today-page .section", "borderLeftWidth")).to eq("0px")
          expect(computed_style(".today-page .section", "borderTopLeftRadius")).to eq("0px")
          expect(sideways_overflow).to eq(0)
        end
      end
    end

    it "keeps the page inside 320px with the largest text and the spacing override" do
      visit_today(width: 320, prefs: LayoutHelpers::LARGEST_TEXT)
      apply_text_spacing

      expect(sideways_overflow).to eq(0)
    end

    it "keeps a trial's banner 16px under the title block" do
      visit_today(user: create_trial_user)

      expect(rect(".trial-banner")["top"] - rect(".today-page .page-header")["bottom"]).to be_within(0.5).of(16)
    end

    it "moves the cards in to a side inset wider than 16px" do
      set_safe_area(left: 20, right: 20)
      visit_today

      expect(cards.size).to eq(ExerciseSection::MAX_SECTIONS)
      edges(".today-page .section").each do |left, right|
        expect(left).to be_within(0.5).of(20)
        expect(right).to be_within(0.5).of(20)
      end
    end
  end


  describe "the Submit row" do
    it "comes after the last section, with a button lined up with the cards' text, in a browser tab and the home-screen app" do
      set_safe_area(bottom: 34)
      visit_today

      expect(row_position).to eq("static")
      expect(submit_row["top"]).to be > cards.last["bottom"]
      button = rect("#submit-answers")
      expect(button["left"]).to be_within(0.5).of(cards.first["left"] + 16)
      expect(button["right"]).to be_within(0.5).of(cards.first["right"] - 16)
      expect(button["height"]).to be >= 48

      force_standalone
      expect(row_position).to eq("static")
      expect(submit_row["top"]).to be > cards.last["bottom"]
    end

    it "shows a refused submit's nudge under the button" do
      visit_today
      click_button "Submit answers"

      # The nudge is already visible before submit, so its focus is what says the refusal has landed.
      expect(page).to have_css("#rating-nudge:focus", visible: true)
      nudge, button = page.evaluate_script(<<~JS)
        ["#rating-nudge", "#submit-answers"].map((selector) => document.querySelector(selector).getBoundingClientRect().toJSON())
      JS
      expect(nudge["top"]).to be >= button["bottom"]
    end

    it "brings a held submit's notice on screen" do
      visit_today
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

      expect(page).to have_css("#leave-held")
      notice = rect("#leave-held")
      expect(notice["top"]).to be >= 0
      # Scroll positions snap to whole pixels, so allow a sub-pixel overlap.
      expect(notice["bottom"]).to be <= window_height + 0.5
    end

    it "keeps every rating button 44px tall and the button 48px at 320px with the largest text" do
      visit_today(width: 320, prefs: LayoutHelpers::LARGEST_TEXT)

      expect(rects(".rating-row .rating-btn").map { |r| r["height"] }).to all(be >= 44)
      expect(rect("#submit-answers")["height"]).to be >= 48
    end
  end

  it "applies the phone rules below 600px, with full-width cards, and not at 600px" do
    visit_today(width: 599)
    expect(edges(".today-page .section").first.first).to be_within(0.5).of(0)
    expect(rect("#submit-answers")["width"]).to be_within(0.5).of(cards.first["width"] - 32)

    resize(600)
    expect(edges(".today-page .section").first.first).to be_within(0.5).of(24)
    expect(computed_style(".today-page .section", "marginBottom")).to eq("24px")
    expect(rect("#submit-answers")["width"]).to be < cards.first["width"] / 2
  end
end
