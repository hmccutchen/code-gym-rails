require "rails_helper"

RSpec.describe "Review takeaway and full review", type: :system, with_csrf: true do
  let(:user) { create_fake_provider_user }
  let(:takeaway) do
    "The loop repeats a query that eager loading could avoid. " \
      "Load the association named `customer_billing_address_for_the_monthly_account_summary` before the loop."
  end

  around { |example| travel_to(a_weekday) { example.run } }

  before { stub_env("REVIEW_TAKEAWAY" => "1") }

  def reviewed_day(date: Date.current)
    exercise = DailyExercise.create!(
      user: user, date: date, generated_at: Time.current, language: "ruby_rails",
      problem_set: { "code_review" => { "question" => "Why does the loop run extra queries?", "snippet" => "orders.each { |o| o.customer }" } }
    )
    DailyResponse.create!(
      user: user, daily_exercise: exercise, date: date, submitted_at: Time.current,
      answers: { "code_review" => "The loop could run more quickly." }, section_ratings: { "code_review" => "right_level" },
      concept_tags: { "code_review" => "n_plus_one" },
      ai_review: {
        "code_review" => {
          "rating" => "developing", "rubric" => ReviewedSectionResults::RUBRIC_VERSION,
          "correct" => [ "You noticed that the loop could be slow." ], "missed" => [ takeaway ], "essential_gaps" => [ 0 ]
        }
      }
    )
  end

  def press(key)
    page.driver.with_playwright_page { |browser| browser.keyboard.press(key) }
  end

  def tap(selector)
    page.execute_script("document.querySelector(#{selector.to_json}).scrollIntoView({ block: 'center' })")
    box = rect(selector)
    point = { x: box.fetch("left") + box.fetch("width") / 2, y: box.fetch("top") + box.fetch("height") / 2 }
    cdp_session.send_message("Input.dispatchTouchEvent", params: { type: "touchStart", touchPoints: [ point ] })
    cdp_session.send_message("Input.dispatchTouchEvent", params: { type: "touchEnd", touchPoints: [] })
  end

  def expect_tooltip_inside_viewport
    panel = page.evaluate_script(<<~JS)
      (() => {
        const term = document.querySelector(".gloss-open");
        const style = getComputedStyle(term, "::after");
        const left = term.getBoundingClientRect().left + parseFloat(style.left);
        return [style.display, left, left + parseFloat(style.width)];
      })()
    JS
    expect(panel[0]).to eq("block")
    expect(panel[1]).to be >= 0
    expect(panel[2]).to be <= client_width
  end

  def chevron_transform(selector)
    page.evaluate_script("getComputedStyle(document.querySelector(#{selector.to_json}), '::before').transform")
  end

  def summary_accessibility
    summary = cdp_session.send_message("Runtime.evaluate", params: { expression: "document.querySelector('details.review-full > summary')" })
    tree = cdp_session.send_message("Accessibility.getPartialAXTree",
                                      params: { objectId: summary.dig("result", "objectId"), fetchRelatives: false })
    node = tree.fetch("nodes").sole
    expanded = node.fetch("properties").find { |property| property["name"] == "expanded" }
    [ node.dig("name", "value"), expanded&.dig("value", "value") ]
  end

  it "keeps the takeaway readable and the glossary accessible as Today's 360px review opens and closes" do
    reviewed_day
    resize(360, height: 800)
    visit_as(user)
    wait_for_js

    expect(page).to have_css(".review-takeaway", text: "Main takeaway", wait: 0)
    expect(page).to have_css(".review-takeaway code", text: /monthly_account_summary/)
    expect(page).to have_css("details.review-full:not([open])")
    expect(summary_accessibility).to eq([ "Full review for Code review", false ])
    expect(page).to have_no_css("details.review-full .review-item")
    expect(page).to have_css(".review-block > .follow-ups input")
    expect(page).to have_css(".review-rating", text: "developing")
    expect(sideways_overflow).to eq(0)

    tap(".review-takeaway .gloss-term")
    expect(page).to have_css(".review-takeaway .gloss-term.gloss-open", text: "eager loading")
    expect_tooltip_inside_viewport

    find("details.review-full > summary").send_keys(:enter)
    expect(page).to have_css("details.review-full[open] > summary:focus")
    expect(summary_accessibility).to eq([ "Full review for Code review", true ])
    expect(page).to have_css(".review-takeaway", text: "The loop repeats a query")
    expect(page).to have_css("details.review-full .review-item", text: "The loop repeats a query")
    expect(sideways_overflow).to eq(0)

    find("details.review-full .gloss-term", text: "eager loading").send_keys(:space)
    expect(page).to have_css("details.review-full .gloss-term.gloss-open", text: "eager loading")
    expect(page).to have_css(".gloss-open", count: 1)

    find("details.review-full > summary").send_keys(:space)
    expect(page).to have_css("details.review-full:not([open]) > summary:focus")
    press("Tab")
    expect(page).to have_css(".follow-ups input:focus")
    find("details.review-full > summary").send_keys(:enter)
    expect(page).to have_css("details.review-full[open]")
    expect(page).to have_no_css("details.review-full .gloss-open", visible: :all)
  end

  it "opens an older History entry separately from its Full review and Short version" do
    date = Date.current - 2
    older_day = reviewed_day(date: date)
    reviewed_day(date: Date.current - 1)
    ConceptReference.create!(user: user, concept: "n_plus_one", language: "ruby_rails",
                             tagline: "Load what the loop reads in one query", explanation: "Preload associations used in loops.",
                             code_example: "Order.includes(:customer)", senior_lens: "Consider the cost of preloading.")
    resize(360, height: 800)
    visit_as(user)
    visit history_path
    wait_for_js
    page.driver.with_playwright_page { |browser| browser.emulate_media(reducedMotion: "reduce") }

    entry = "#response-#{older_day.id}"
    within(entry) do
      expect(page).to have_css("details.review:not([open])", wait: 0)
      expect(page).to have_no_css(".review-takeaway")
      find("details.review > summary", match: :first).click
      expect(page).to have_css(".review-takeaway", text: "The loop repeats a query", wait: 0)
      expect(page).to have_css("details.review-full:not([open])")
      expect(page).to have_no_css("details.review-short-version")
      outer = chevron_transform("#{entry} > details.review > summary")
      inner = chevron_transform("#{entry} details.review-full > summary")
      expect(inner).not_to eq(outer)
      find("details.review-full > summary").click
      expect(chevron_transform("#{entry} > details.review > summary")).to eq(outer)
      expect(chevron_transform("#{entry} details.review-full > summary")).not_to eq(inner)
      expect(page).to have_css(".review-takeaway", text: "The loop repeats a query")
      expect(page).to have_css("details.review-short-version:not([open])")
      find("details.review-short-version > summary").click
      expect(page).to have_css("details.review-full[open] details.review-short-version[open]")
      expect(sideways_overflow).to eq(0)
    end
  end

  it "keeps the pending follow-up and saved thread attached when Full review is toggled" do
    response = reviewed_day
    requested = Queue.new
    release = Queue.new
    allow_any_instance_of(FakeService).to receive(:answer_follow_up).and_wrap_original do |original, *args, **options|
      requested << options.fetch(:question)
      raise "Follow-up test did not release the fake reply" unless release.pop(timeout: Capybara.default_max_wait_time)

      original.call(*args, **options)
    end

    visit_as(user)
    wait_for_js
    expect(page).to have_css("details.review-full:not([open])", wait: 0)
    find(".follow-ups input").fill_in(with: "Why eager loading?")
    within(".follow-ups") { click_button "Ask" }
    expect(page).to have_css(".follow-ups input:disabled")
    expect(page).to have_css(".follow-up-status[aria-live]", text: "Thinking")
    expect(requested.pop(timeout: Capybara.default_max_wait_time)).to eq("Why eager loading?")

    find("details.review-full > summary").send_keys(:enter)
    expect(page).to have_css("details.review-full[open] > summary:focus")
    find("details.review-full > summary").send_keys(:space)
    expect(page).to have_css("details.review-full:not([open]) > summary:focus")
    release << true

    expect(page).to have_css(".follow-up-thread[aria-live='polite'] .follow-up-assistant", text: FakeService::FOLLOW_UP_ANSWER_TEXT)
    expect(page).to have_css("details.review-full:not([open]) > summary:focus")
    expect(response.reload.follow_up_turns("code_review").map(&:content)).to eq([ "Why eager loading?", FakeService::FOLLOW_UP_ANSWER_TEXT ])
    expect(requested).to be_empty
  ensure
    release << true if release
  end

  it "keeps the follow-up draft after a provider failure and retries from outside Full review" do
    response = reviewed_day
    response.append_follow_up!("code_review", question: "What was right?", answer: "You found the slow loop.")
    attempts = 0
    allow_any_instance_of(FakeService).to receive(:answer_follow_up).and_wrap_original do |original, *args, **options|
      attempts += 1
      raise ProviderError, "Unavailable" if attempts == 1

      original.call(*args, **options)
    end

    visit_as(user)
    wait_for_js
    expect(page).to have_css("details.review-full:not([open])", wait: 0)

    within(".follow-ups") do
      find("input").fill_in(with: "Why eager loading?")
      click_button "Ask"
      expect(page).to have_css(".follow-up-status[aria-live]", text: /try again/i)
      expect(find("input").value).to eq("Why eager loading?")
      expect(page).to have_css(".follow-up-turn", text: "You found the slow loop.")
      expect(response.review_follow_ups.reload.size).to eq(2)
      click_button "Ask"
      expect(page).to have_css(".follow-up-assistant", text: FakeService::FOLLOW_UP_ANSWER_TEXT)
    end
    expect(page).to have_css("details.review-full:not([open])")
    expect(attempts).to eq(2)
    expect(response.review_follow_ups.reload.size).to eq(4)
  end
end
