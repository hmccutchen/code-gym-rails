# One-time local setup for spec/system/ (CI runs the equivalent in
# .github/workflows/ci.yml): install a Playwright CLI version matched to the
# playwright-ruby-client gem, then have it download a Chromium build.
#
#   export PLAYWRIGHT_CLI_VERSION=$(bundle exec ruby -e 'require "playwright/version"; puts Playwright::COMPATIBLE_PLAYWRIGHT_VERSION')
#   npm install "playwright-core@$PLAYWRIGHT_CLI_VERSION"
#   ./node_modules/.bin/playwright-core install --with-deps chromium
#
# capybara-playwright-driver must NOT be registered under the name :playwright
# — Rails 6.1+ reserves that name for its own built-in Playwright driver, which
# would silently take over instead. Registered here as :capybara_playwright.
Capybara.register_driver(:capybara_playwright) do |app|
  Capybara::Playwright::Driver.new(
    app,
    browser_type: :chromium,
    headless: true,
    playwright_cli_executable_path: Rails.root.join("node_modules/.bin/playwright-core").to_s
  )
end

# Capybara's 2s default wait is too short for a real browser round-tripping
# through this app's fetch-based autosave/submit/status-poll flows.
Capybara.default_max_wait_time = 10

RSpec.configure do |config|
  config.before(:each, type: :system) do
    driven_by :capybara_playwright
  end

  # GenerateDailyExercisesJob runs via ActiveJob's :test adapter (see
  # config/environments/test.rb) — system specs that trigger on-demand
  # generation need to actually run it, not just assert it was enqueued.
  config.include ActiveJob::TestHelper, type: :system
end
