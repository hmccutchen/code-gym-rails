# One-time local setup for spec/system/ (CI runs the same commands in
# .github/workflows/ci.yml): install the pinned Playwright CLI from the
# committed lockfile, then have it download a Chromium build.
#
#   npm --prefix spec/playwright ci
#   ./spec/playwright/node_modules/.bin/playwright-core install --with-deps chromium
#
# The npm manifests deliberately live in spec/playwright/, NOT the repo root:
# Railway builds with Nixpacks, whose Ruby provider installs Node and runs an
# npm install whenever it finds a root package.json. This app is importmap-only
# and needs no Node in production, so keeping the manifests out of the root
# leaves the production build untouched.
#
# `npm ci` (not `npm install`) so the lockfile is never rewritten as a side
# effect of setup. The pinned CLI version must match what playwright-ruby-client
# expects, so bump it deliberately alongside the gem:
#
#   npm --prefix spec/playwright install --save-exact \
#     "playwright-core@$(bundle exec ruby -e 'require "playwright/version"; puts Playwright::COMPATIBLE_PLAYWRIGHT_VERSION')"
#
# capybara-playwright-driver must NOT be registered under the name :playwright
# — Rails 6.1+ reserves that name for its own built-in Playwright driver, which
# would silently take over instead. Registered here as :capybara_playwright.
PLAYWRIGHT_CLI_PATH = Rails.root.join("spec/playwright/node_modules/.bin/playwright-core")

Capybara.register_driver(:capybara_playwright) do |app|
  Capybara::Playwright::Driver.new(
    app,
    browser_type: :chromium,
    headless: true,
    playwright_cli_executable_path: PLAYWRIGHT_CLI_PATH.to_s
  )
end

# Playwright launches Chromium with --disable-back-forward-cache among its
# default switches, so a Back navigation always re-fetches and `pageshow`
# never fires with `persisted` true. The dashboard's Back-restore handler
# (dashboard/_exercise.html.erb) is unreachable under the default driver —
# a spec written against it would pass just as well with the handler deleted.
# Opt into this driver from the one example that needs a real bfcache restore.
Capybara.register_driver(:capybara_playwright_bfcache) do |app|
  Capybara::Playwright::Driver.new(
    app,
    browser_type: :chromium,
    headless: true,
    ignoreDefaultArgs: [ "--disable-back-forward-cache" ],
    playwright_cli_executable_path: PLAYWRIGHT_CLI_PATH.to_s
  )
end

# Capybara's 2s default wait is too short for a real browser round-tripping
# through this app's fetch-based autosave/submit/status-poll flows.
Capybara.default_max_wait_time = 10

# System specs need a weekday (the dashboard only generates Mon-Fri), but
# unlike request specs they cannot travel_to an arbitrary one: `travel_to`
# stubs the clock in *our* process only, while Chromium stamps cookies
# against the real wall clock. The session cookie carries
# `expire_after: 2.days` (config/initializers/session_store.rb) measured
# from the travelled time, so travelling more than two days into the past
# hands the browser an already-expired cookie, which it silently drops —
# login appears to succeed, then the next request bounces to /login.
#
# Picking today when it's a weekday, and otherwise the upcoming Monday,
# keeps the travelled clock at most a day *behind* real time (midnight of
# the current day). It can run further ahead than that — from Saturday the
# next Monday is up to two days out — but only backward travel can expire
# the cookie, so forward drift is harmless.
module SystemTimeHelper
  def a_weekday
    date = Date.current
    date = date.next_occurring(:monday) if date.on_weekend?
    date
  end
end

# The dashboard's Submit button is gated on every section on the page having a
# rating (app/views/dashboard/_exercise.html.erb's allRated(), keyed off every
# `textarea[data-field]` present) — not on a fixed count of three. Specs that
# hardcode which fields to rate silently drift out of sync whenever a section
# slot is added or a fixture resolves to a different kind, so this reads the
# fields that are actually on the page instead of naming them.
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

RSpec.configure do |config|
  config.before(:each, type: :system) do
    driven_by :capybara_playwright
  end

  # GenerateDailyExercisesJob runs via ActiveJob's :test adapter (see
  # config/environments/test.rb) — system specs that trigger on-demand
  # generation need to actually run it, not just assert it was enqueued.
  config.include ActiveJob::TestHelper, type: :system

  config.include SystemTimeHelper, type: :system
  config.include RatingHelper, type: :system
end
