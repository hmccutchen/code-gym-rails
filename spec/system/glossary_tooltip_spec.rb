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
    expect(page).to have_content(/Code Review/i, wait: 10)
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

  it "re-fits an already-open panel after the device is rotated" do
    user = create_fake_provider_user
    landscape_width = 568

    travel_to(a_weekday) do
      # Landscape to portrait: a panel sized for the wider screen is the one that stops fitting.
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
end
