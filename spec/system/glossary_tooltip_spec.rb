require "rails_helper"

RSpec.describe "Glossary tooltips on a phone-sized viewport", type: :system do
  # The exercise is built here rather than generated through FakeService because
  # this bug only reproduces when the term sits away from the left edge: the old
  # panel was anchored at the term and ran off screen only once the term was far
  # enough right. FakeService's own wording happens to wrap "loyalty tier" to the
  # start of a line, where no overflow is possible.
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

  # Opens the panel and reports how far the page can scroll horizontally before
  # and after. The document already overflows slightly at this width because of
  # the code snippet, so the meaningful assertion is that opening a panel adds
  # nothing to it — not that the total is zero.
  def open_panel_and_measure
    page.evaluate_script(<<~JS)
      (() => {
        const term = Array.from(document.querySelectorAll(".gloss-term"))
          .find((el) => /loyalty tier/i.test(el.textContent));
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

    travel_to(Date.current.beginning_of_week(:monday)) do
      page.current_window.resize_to(phone_width, 800)
      start_dashboard(user, question: "The customer loyalty tier")

      box = open_panel_and_measure

      expect(box["found"]).to be(true)
      expect(box["display"]).to eq("block")
      # Guards the fixture itself: if the text ever reflows so the term starts at
      # the left edge, the panel could not overflow and the assertion below would
      # pass without testing anything.
      expect(box["termLeft"]).to be > phone_width * 0.25
      expect(box["scrollAfter"]).to be <= box["scrollBefore"]
    end
  end

  # The panel is also revealed by :focus-visible and by hover on hover-capable
  # pointers, neither of which runs the positioning script. Those paths get no
  # custom properties, so the fallbacks alone have to keep the panel capped.
  it "keeps the desktop width cap when the positioning script has not measured a term" do
    user = create_fake_provider_user

    travel_to(Date.current.beginning_of_week(:monday)) do
      page.current_window.resize_to(phone_width, 800)
      start_dashboard(user, question: "The customer loyalty tier")

      capped = page.evaluate_script(<<~JS)
        (() => {
          const term = Array.from(document.querySelectorAll(".gloss-term"))
            .find((el) => /loyalty tier/i.test(el.textContent));
          const style = getComputedStyle(term, "::after");
          return { maxWidth: style.maxWidth, left: style.left };
        })()
      JS

      expect(capped["maxWidth"]).to eq("256px")
      expect(capped["left"]).to eq("0px")
    end
  end

  it "re-fits an already-open panel after the device is rotated" do
    user = create_fake_provider_user
    landscape_width = 568

    travel_to(Date.current.beginning_of_week(:monday)) do
      # Rotated landscape → portrait, not the reverse: a panel sized for the
      # wider screen is the one that no longer fits after the rotation.
      page.current_window.resize_to(landscape_width, 320)
      start_dashboard(user, question: "The customer loyalty tier")
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
