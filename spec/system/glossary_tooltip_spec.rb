require "rails_helper"

RSpec.describe "Glossary tooltips on a phone-sized viewport", type: :system do
  # Built by hand, not via FakeService: the overflow only reproduces with the term away from the left edge.
  let(:phone_width) { 320 }

  def start_dashboard(user, question:)
    problem_set = FakeService::EXERCISE_PROBLEM_SET.deep_dup
    problem_set["code_review"]["question"] = question
    problem_set["code_review"]["scenario"] = "x"

    DailyExercise.create!(user: user, date: Date.current, language: "ruby_rails",
                          generated_at: Time.current, problem_set: problem_set)
    visit_as(user)
    expect(page).to have_content(/Code Review/i)
  end

  # The page already overflows slightly from the snippet, so assert opening a panel adds nothing, not a zero total.
  def open_panel_and_measure
    page.evaluate_script(<<~JS)
      (() => {
        const term = Array.from(document.querySelectorAll(".gloss-term"))
          .find((el) => /memoization/i.test(el.textContent));
        if (!term) return { found: false };
        const before = document.documentElement.scrollWidth;
        term.click();
        return {
          found: true,
          termLeft: term.getBoundingClientRect().left,
          display: getComputedStyle(term, "::after").display,
          scrollBefore: before,
          scrollAfter: document.documentElement.scrollWidth
        };
      })()
    JS
  end

  it "keeps an opened definition panel from running off the side of the screen" do
    user = create_fake_provider_user

    travel_to(a_weekday) do
      page.current_window.resize_to(phone_width, 800)
      start_dashboard(user, question: "The customer memoization")

      box = open_panel_and_measure

      expect(box["found"]).to be(true)
      expect(box["display"]).to eq("block")
      # Guards the fixture: a term at the left edge could not overflow, so the assertion below would test nothing.
      expect(box["termLeft"]).to be > phone_width * 0.25
      expect(box["scrollAfter"]).to be <= box["scrollBefore"]
    end
  end

  # :focus-visible and hover skip the positioning script, so the CSS fallbacks alone must cap the panel.
  it "keeps the desktop width cap when the positioning script has not measured a term" do
    user = create_fake_provider_user

    travel_to(a_weekday) do
      page.current_window.resize_to(phone_width, 800)
      start_dashboard(user, question: "The customer memoization")

      capped = page.evaluate_script(<<~JS)
        (() => {
          const term = Array.from(document.querySelectorAll(".gloss-term"))
            .find((el) => /memoization/i.test(el.textContent));
          const style = getComputedStyle(term, "::after");
          return { maxWidth: style.maxWidth, left: style.left };
        })()
      JS

      expect(capped["maxWidth"]).to eq("256px")
      expect(capped["left"]).to eq("0px")
    end
  end

  # Keyboard focus fires no click, so the panel must be measured on focus too; a width cap alone still overflows.
  it "keeps the panel on screen when it is revealed by keyboard focus" do
    user = create_fake_provider_user

    travel_to(a_weekday) do
      page.current_window.resize_to(phone_width, 800)
      start_dashboard(user, question: "The customer memoization")

      box = page.evaluate_script(<<~JS)
        (() => {
          const term = Array.from(document.querySelectorAll(".gloss-term"))
            .find((el) => /memoization/i.test(el.textContent));
          term.focus();
          const style = getComputedStyle(term, "::after");
          const left = term.getBoundingClientRect().left + parseFloat(style.left);
          return {
            display: style.display,
            termLeft: term.getBoundingClientRect().left,
            left: left,
            right: left + parseFloat(style.width)
          };
        })()
      JS

      expect(box["display"]).to eq("block")
      expect(box["termLeft"]).to be > phone_width * 0.25
      expect(box["left"]).to be >= 0
      expect(box["right"]).to be <= phone_width
    end
  end

  it "re-fits an already-open panel after the device rotates from landscape to portrait" do
    user = create_fake_provider_user
    landscape_width = 568

    travel_to(a_weekday) do
      page.current_window.resize_to(landscape_width, 320)
      start_dashboard(user, question: "The customer memoization")
      open_panel_and_measure

      page.current_window.resize_to(phone_width, 800)

      box = page.evaluate_script(<<~JS)
        (() => {
          const term = document.querySelector(".gloss-term.gloss-open");
          const style = getComputedStyle(term, "::after");
          const left = term.getBoundingClientRect().left + parseFloat(style.left);
          return { left: left, right: left + parseFloat(style.width) };
        })()
      JS

      expect(box["left"]).to be >= 0
      expect(box["right"]).to be <= phone_width
    end
  end

  describe "on Learn and in a concept reference" do
    def term_missing = "no .gloss-term containing memoization was found"

    let(:learn_tagline) { "Memoization keeps repeated reads cheap." }
    let(:worked_example) { "Each read hits the database again, so caching the result avoids it, so memoization helps." }

    def create_reference(tagline:, worked_example: FakeService::CONCEPT_REFERENCE["guide_worked_example"])
      ConceptReference.create!(
        FakeService::CONCEPT_REFERENCE.except("lesson").merge(
          "concept" => "n_plus_one", "language" => "ruby_rails",
          "tagline" => tagline, "guide_worked_example" => worked_example
        )
      )
    end

    def visit_learn_concept(user)
      create_reference(tagline: learn_tagline, worked_example: worked_example)
      visit_as(user)
      visit learn_concept_path(bucket: "ruby_rails", concept: "n_plus_one")
      expect(page).to have_content(learn_tagline)
      wait_for_js
    end

    def memoization_term_js(scope: "")
      <<~JS
        Array.from(document.querySelectorAll("#{scope} .gloss-term"))
          .filter((el) => /memoization/i.test(el.textContent))
      JS
    end

    def scroll_to_term(index, scope: "")
      page.evaluate_script(<<~JS)
        (() => {
          const term = (#{memoization_term_js(scope: scope)})[#{index}];
          if (!term) return { found: false };
          term.scrollIntoView({ block: "center" });
          return { found: true };
        })()
      JS
    end

    def click_term_centre(index, scope: "")
      point = page.evaluate_script(<<~JS)
        (() => {
          const term = (#{memoization_term_js(scope: scope)})[#{index}];
          const rect = term.getBoundingClientRect();
          return { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
        })()
      JS
      page.driver.with_playwright_page { |pw| pw.mouse.click(point["x"], point["y"]) }
    end

    def panel_box(index, scope: "")
      page.evaluate_script(<<~JS)
        (() => {
          const term = (#{memoization_term_js(scope: scope)})[#{index}];
          const style = getComputedStyle(term, "::after");
          const left = term.getBoundingClientRect().left + parseFloat(style.left);
          return {
            display: style.display,
            left: left,
            right: left + parseFloat(style.width),
            width: parseFloat(style.width),
            scrollWidth: document.documentElement.scrollWidth
          };
        })()
      JS
    end

    def press(key)
      page.driver.with_playwright_page { |pw| pw.keyboard.press(key) }
    end

    def open_term_count = page.evaluate_script('document.querySelectorAll(".gloss-open").length')

    def term_open?(index)
      page.evaluate_script("(#{memoization_term_js})[#{index}].classList.contains('gloss-open')")
    end

    def focus_term(index)
      page.execute_script("(#{memoization_term_js})[#{index}].focus()")
    end

    it "opens a tapped term's panel inside a 320px Learn page" do
      user = create_fake_provider_user
      page.current_window.resize_to(phone_width, 800)
      visit_learn_concept(user)

      [ 0, 1 ].each do |index|
        expect(scroll_to_term(index)["found"]).to be(true), term_missing
        click_term_centre(index)
        box = panel_box(index)

        expect(box["display"]).to eq("block")
        expect(box["width"]).to be > 0
        expect(box["left"]).to be >= 0
        expect(box["right"]).to be <= phone_width
        expect(box["scrollWidth"]).to eq(phone_width)
      end
    end

    it "opens the dropdown's term inside the viewport on the dashboard at 320px" do
      user = create_fake_provider_user

      travel_to(a_weekday) do
        page.current_window.resize_to(phone_width, 800)
        create_reference(tagline: learn_tagline)
        start_dashboard(user, question: "x")
        wait_for_js
        expect(page).to have_css("details.ref[open]")

        expect(scroll_to_term(0, scope: ".ref-body")["found"]).to be(true), term_missing
        click_term_centre(0, scope: ".ref-body")
        box = panel_box(0, scope: ".ref-body")

        expect(box["width"]).to be > 0
        expect(box["left"]).to be >= 0
        expect(box["right"]).to be <= phone_width
      end
    end

    it "toggles a Learn term with Enter and Space and keeps one panel open" do
      user = create_fake_provider_user
      page.current_window.resize_to(phone_width, 800)
      visit_learn_concept(user)

      expect([ scroll_to_term(1)["found"], scroll_to_term(0)["found"] ]).to eq([ true, true ]), term_missing
      focus_term(0)
      press("Enter")
      expect(term_open?(0)).to be(true)
      press("Space")
      expect(term_open?(0)).to be(false)

      press("Enter")
      focus_term(1)
      press("Enter")
      expect(open_term_count).to eq(1)
      expect([ term_open?(0), term_open?(1) ]).to eq([ false, true ])
    end

    it "opens a Learn term on a desktop click" do
      user = create_fake_provider_user
      page.driver.with_playwright_page { |pw| pw.set_viewport_size(width: 1024, height: 768) }
      begin
        visit_learn_concept(user)

        expect(scroll_to_term(0)["found"]).to be(true), term_missing
        click_term_centre(0)

        expect(term_open?(0)).to be(true)
        expect(panel_box(0)["display"]).to eq("block")
      ensure
        page.driver.with_playwright_page { |pw| pw.set_viewport_size(width: phone_width, height: 800) }
      end
    end
  end
end
