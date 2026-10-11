PLAYWRIGHT_CLI_PATH = Rails.root.join("spec/playwright/node_modules/.bin/playwright-core")

# Not :playwright, which Rails reserves for its own driver and would silently take over.
Capybara.register_driver(:capybara_playwright) do |app|
  Capybara::Playwright::Driver.new(
    app,
    browser_type: :chromium,
    headless: true,
    playwright_cli_executable_path: PLAYWRIGHT_CLI_PATH.to_s
  )
end

# Playwright's default --disable-back-forward-cache makes the Back-restore handler unreachable under the default driver.
Capybara.register_driver(:capybara_playwright_bfcache) do |app|
  Capybara::Playwright::Driver.new(
    app,
    browser_type: :chromium,
    headless: true,
    ignoreDefaultArgs: [ "--disable-back-forward-cache" ],
    playwright_cli_executable_path: PLAYWRIGHT_CLI_PATH.to_s
  )
end

# Capybara's 2s default is too short for this app's fetch-based autosave, submit and status-poll flows.
Capybara.default_max_wait_time = 10

# travel_to more than two days back would hand Chromium an already-expired session cookie.
module SystemTimeHelper
  def a_weekday
    date = Date.current
    date = date.next_occurring(:monday) if date.on_weekend?
    date
  end
end

module RatingHelper
  def rating_row_fields
    all(".rating-row[data-rating-for]", visible: :all).map { |row| row["data-rating-for"] }.uniq
  end

  def rate_section(field, value: "right_level")
    find(%(button[data-rating-for="#{field}"][data-rating="#{value}"])).click
  end

  def rate_all_sections(value: "right_level")
    rating_row_fields.each { |field| rate_section(field, value: value) }
  end
end

module AnswerFormHelper
  def fill_in_answer(field, text)
    comparison = first(%([data-comparison-answer="#{field}"]), minimum: 0)
    return find(%(textarea[data-field="#{field}"])).fill_in(with: text) unless comparison

    comparison.choose("Piece A")
    comparison.find("textarea[data-comparison-reason]").fill_in(with: text)
  end

  def expect_ready_to_submit
    expect(page).to have_selector("#rating-nudge", visible: :hidden)
  end
end

module TodaysSetHelper
  def visit_with_todays_set(user)
    perform_enqueued_jobs do
      GenerateDailyExercisesJob.perform_now(user_id: user.id)
      visit_as(user)
    end
  end
end

module JavascriptReadyHelper
  def wait_for_js
    expect(page).to have_css("html[data-js-ready]", visible: :all)
  end

  NAVIGATED_AWAY = /Execution context was destroyed|Cannot find context|Target closed/

  def wait_for_js_condition(expression, timeout: Capybara.default_max_wait_time)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    page.driver.with_playwright_page do |pw|
      loop do
        begin
          break if pw.evaluate("Boolean(#{expression})")
        rescue Playwright::Error => error
          raise unless error.message.to_s.match?(NAVIGATED_AWAY)
        end
        raise "timed out waiting for #{expression}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.05
      end
    end
  end
end

RSpec.configure do |config|
  config.before(:each, type: :system) do
    driven_by :capybara_playwright
  end

  # System specs that trigger on-demand generation need to run the job, not just assert it was enqueued.
  config.include ActiveJob::TestHelper, type: :system

  config.include SystemTimeHelper, type: :system
  config.include RatingHelper, type: :system
  config.include AnswerFormHelper, type: :system
  config.include TodaysSetHelper, type: :system
  config.include JavascriptReadyHelper, type: :system
end
