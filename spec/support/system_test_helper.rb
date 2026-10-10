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

module TodaysSetHelper
  def visit_with_todays_set(user)
    perform_enqueued_jobs do
      GenerateDailyExercisesJob.perform_now(user_id: user.id)
      visit_as(user)
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
  config.include TodaysSetHelper, type: :system
end
