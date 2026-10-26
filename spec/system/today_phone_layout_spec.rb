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

  def bar = rect("#submit-row")

  def focus_ring_reach
    page.evaluate_script(<<~JS)
      (() => {
        const style = getComputedStyle(document.documentElement);
        return parseFloat(style.getPropertyValue("--focus-ring-width")) + parseFloat(style.getPropertyValue("--focus-ring-offset"));
      })()
    JS
  end

  def bar_position = computed_style("#submit-row", "position")

  describe "the section cards" do
    [ 320, 390 ].each do |width|
      [ {}, LayoutHelpers::LARGEST_TEXT ].each do |prefs|
        it "insets each section as a card 16px from the edges, 16px apart, at #{width}px#{' with the largest text' if prefs.any?}" do
          visit_today(width: width, prefs: prefs)

          expect(cards.size).to eq(ExerciseSection::MAX_SECTIONS)
          edges(".today-page .section").each do |left, right|
            expect(left).to be_within(0.5).of(16)
            expect(right).to be_within(0.5).of(16)
          end
          cards.each_cons(2) { |upper, lower| expect(lower["top"] - upper["bottom"]).to be_within(0.5).of(16) }
          expect(computed_style(".today-page .section", "borderLeftWidth")).to eq("1px")
          expect(computed_style(".today-page .section", "borderTopLeftRadius")).not_to eq("0px")
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

  describe "the Submit bar" do
    it "sits at the bottom of a browser tab over the sections, as wide as the cards" do
      visit_today

      expect(bar["bottom"]).to be_within(0.5).of(window_height)
      expect(bar["top"]).to be < cards.last["bottom"]
      button = rect("#submit-answers")
      expect(button["left"]).to be_within(0.5).of(cards.first["left"])
      expect(button["right"]).to be_within(0.5).of(cards.first["right"])
      expect(button["height"]).to be >= 48
    end

    it "keeps the button above a browser tab's bottom safe area" do
      set_safe_area(bottom: 34)
      visit_today

      expect(bar["bottom"]).to be_within(0.5).of(window_height)
      expect(rect("#submit-answers")["bottom"]).to be <= window_height - 34
    end

    it "sits on top of the tab bar in the home-screen app" do
      set_safe_area(bottom: 34)
      visit_today
      force_standalone

      tab_bar = rect(".tab-bar")
      expect(tab_bar["bottom"]).to be_within(0.5).of(window_height)
      # The tab bar's 1px top border sits over the bar's bottom edge.
      expect(bar["bottom"]).to be_within(1).of(tab_bar["top"])
      expect(rect("#submit-answers")["bottom"]).to be <= tab_bar["top"] - 8 + 0.5
    end

    it "settles after the last section once the page is scrolled to its end" do
      visit_today
      page.execute_script("window.scrollTo(0, document.documentElement.scrollHeight)")

      expect(bar["top"]).to be >= cards.last["bottom"]
    end

    it "lets go while an answer field has focus, so it never covers the typing" do
      visit_today
      find(%(textarea[data-field="code_review"])).click
      expect(bar_position).to eq("static")
      expect(computed_style("html", "scrollPaddingBottom")).to eq("auto")

      find(".today-page .page-header h1").click
      expect(bar_position).to eq("sticky")
    end

    it "shows a refused submit's nudge inside the bar, on screen" do
      visit_today
      click_button "Submit answers"

      expect(page).to have_css("#rating-nudge", visible: true)
      nudge = rect("#rating-nudge")
      expect(nudge["top"]).to be >= bar["top"]
      expect(nudge["bottom"]).to be <= bar["bottom"]
      expect(bar["bottom"]).to be_within(0.5).of(window_height)
    end

    [ [ 390, {} ], [ 390, LayoutHelpers::LARGEST_TEXT ], [ 320, LayoutHelpers::LARGEST_TEXT ] ].each do |width, prefs|
      it "keeps a focused rating button and its ring above the bar at #{width}px#{' with the largest text' if prefs.any?}" do
        visit_today(width: width, prefs: prefs)
        page.execute_script(<<~JS)
          const button = document.querySelectorAll(".rating-row .rating-btn")[4];
          window.scrollTo(0, 0);
          window.scrollBy(0, button.getBoundingClientRect().bottom - window.innerHeight + 40);
          button.focus({ preventScroll: true });
          button.scrollIntoView({ block: "nearest" });
        JS

        button = page.evaluate_script("document.activeElement.getBoundingClientRect().bottom")
        # Scroll positions snap to whole pixels, so allow a sub-pixel overlap.
        expect(button + focus_ring_reach).to be <= bar["top"] + 0.5
      end
    end

    it "lifts a failed save's message clear of the bar at 320px with the largest text" do
      visit_today(width: 320, prefs: LayoutHelpers::LARGEST_TEXT)
      fail_requests_to("/responses")
      find(%(textarea[data-field="code_review"])).fill_in(with: "It re-runs the query inside the loop.")
      find(".today-page .page-header h1").click

      expect(page).to have_css("#save-status", visible: true)
      expect(rect("#save-status")["bottom"]).to be <= bar["top"]
    end

    it "fits within the 10rem it reserves with a wrapped nudge at 320px with the largest text" do
      visit_today(width: 320, prefs: LayoutHelpers::LARGEST_TEXT)
      click_button "Submit answers"
      expect(page).to have_css("#rating-nudge", visible: true)

      root_font = page.evaluate_script("parseFloat(getComputedStyle(document.documentElement).fontSize)")
      expect(rect("#rating-nudge")["height"]).to be > root_font * 2
      expect(bar["height"]).to be <= root_font * 10
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
      expect(notice["bottom"]).to be <= window_height
    end

    it "keeps every rating button 44px tall and the button 48px at 320px with the largest text" do
      visit_today(width: 320, prefs: LayoutHelpers::LARGEST_TEXT)

      expect(rects(".rating-row .rating-btn").map { |r| r["height"] }).to all(be >= 44)
      expect(rect("#submit-answers")["height"]).to be >= 48
    end
  end

  it "applies the phone rules below 600px, with the cards' gutter, and not at 600px" do
    visit_today(width: 599)
    expect(bar_position).to eq("sticky")
    expect(edges(".today-page .section").first.first).to be_within(0.5).of(16)

    resize(600)
    expect(bar_position).to eq("static")
    expect(edges(".today-page .section").first.first).to be_within(0.5).of(24)
    expect(computed_style(".today-page .section", "marginBottom")).to eq("24px")
  end
end
