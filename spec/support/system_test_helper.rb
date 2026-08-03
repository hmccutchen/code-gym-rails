# One-time local setup for spec/system/ (CI runs the same commands in
# .github/workflows/ci.yml): install the pinned Playwright CLI from the
# committed lockfile, then have it download a Chromium build.
#
#   npm ci
#   ./node_modules/.bin/playwright-core install --with-deps chromium
#
# `npm ci` (not `npm install`) so the lockfile is never rewritten as a side
# effect of setup. The pinned version must match what playwright-ruby-client
# expects, so bump it deliberately alongside the gem:
#
#   npm install --save-exact "playwright-core@$(bundle exec ruby -e 'require "playwright/version"; puts Playwright::COMPATIBLE_PLAYWRIGHT_VERSION')"
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
