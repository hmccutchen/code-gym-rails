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
Capybara.default_max_wait_time = 20

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
    wait_for_js
  end
end

module JavascriptReadyHelper
  EVERY_CONTROLLER_CONNECTED = <<~JS.squish.freeze
    [...document.querySelectorAll("[data-controller]")].every((element) =>
      element.dataset.controller.split(/\s+/).filter(Boolean).every((identifier) =>
        window.Stimulus.getControllerForElementAndIdentifier(element, identifier)))
  JS

  DRAFT_STORE_PATH = Rails.root.join("app/javascript/code_gym/draft_store.js")

  BOOTSTRAP_PATH = Rails.root.join("app/assets/javascripts/code_gym_bootstrap.js")

  def self.quoted_value_in(source, declaration, path:, indented: false)
    source[/^#{"[ \t]*" if indented}#{Regexp.escape(declaration)} = "([^"\\]+)"$/, 1] or
      raise "Found no `#{declaration} = \"...\"` line in #{path}; JavascriptReadyHelper reads the key from it"
  end
  private_class_method :quoted_value_in

  def self.draft_key_in(source) = quoted_value_in(source, "const KEY", path: DRAFT_STORE_PATH)

  def self.pull_note_key_in(source) = quoted_value_in(source, "var PULL_NOTE", path: BOOTSTRAP_PATH, indented: true)

  DRAFT_KEY = draft_key_in(DRAFT_STORE_PATH.read).freeze
  DRAFT_KEY_JS = DRAFT_KEY.to_json.freeze
  STORED_DRAFT = "JSON.parse(localStorage.getItem(#{DRAFT_KEY_JS}) || 'null')".freeze
  DRAFT_ABSENT = "localStorage.getItem(#{DRAFT_KEY_JS}) === null".freeze
  ANSWERS_SETTLED = "#{DRAFT_ABSENT} && !window.CodeGymSaveStatus.pending()".freeze
  PULL_NOTE_KEY = pull_note_key_in(BOOTSTRAP_PATH.read).freeze
  PULL_NOTE_KEY_JS = PULL_NOTE_KEY.to_json.freeze
  PULL_NOTE_ABSENT = "sessionStorage.getItem(#{PULL_NOTE_KEY_JS}) === null".freeze

  def wait_for_js
    expect(page).to have_css("html[data-js-ready]", visible: :all)
    wait_for_js_condition(EVERY_CONTROLLER_CONNECTED)
  end

  def draft_key_js = DRAFT_KEY_JS

  def stored_draft_js = STORED_DRAFT

  def draft_absent_js = DRAFT_ABSENT

  def wait_for_draft_cleared
    wait_for_js_condition(DRAFT_ABSENT)
  end

  def wait_for_answers_settled
    wait_for_js_condition(ANSWERS_SETTLED)
  end

  def pull_note_key_js = PULL_NOTE_KEY_JS

  def pull_note_absent_js = PULL_NOTE_ABSENT

  def leave_pull_note
    page.execute_script("sessionStorage.setItem(#{PULL_NOTE_KEY_JS}, '1')")
  end

  NAVIGATED_AWAY = /Execution context was destroyed|Cannot find context/

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

module FetchStubHelper
  OFFLINE_REPLY = 'Promise.reject(new TypeError("Failed to fetch"))'.freeze
  SERVER_ERROR_REPLY = <<~JS.squish.freeze
    Promise.resolve(new Response(JSON.stringify({ status: "error", error: "nope" }),
      { status: 500, headers: { "Content-Type": "application/json" } }))
  JS
  SIGNED_OUT_REPLY = <<~JS.squish.freeze
    Promise.resolve(Object.defineProperty(
      new Response("<html><body>Log in</body></html>", { status: 200, headers: { "Content-Type": "text/html" } }),
      "redirected", { value: true }))
  JS

  def stub_fetch(path, reply, prefix: false)
    matches = prefix ? "pathname.startsWith(#{path.to_json})" : "pathname === #{path.to_json}"
    page.execute_script(<<~JS)
      (() => {
        const passThrough = window.fetch;
        window.fetch = (url, options) => {
          const pathname = new URL(String(url), location.href).pathname;
          return #{matches} ? (#{reply.strip.delete_suffix(";")}) : passThrough(url, options);
        };
      })();
    JS
  end

  def fail_requests_to(path) = stub_fetch(path, SERVER_ERROR_REPLY)

  def drop_requests_to(path) = stub_fetch(path, OFFLINE_REPLY)

  def redirect_requests_to_login(path) = stub_fetch(path, SIGNED_OUT_REPLY)

  def break_the_network
    page.execute_script("window.fetch = () => #{OFFLINE_REPLY}")
  end
end

module ComputedColorHelper
  def computed_color(variable)
    page.evaluate_script(<<~JS)
      (() => {
        const probe = document.body.appendChild(Object.assign(document.createElement("span"), { style: "color: var(#{variable})" }));
        const color = getComputedStyle(probe).color;
        probe.remove();
        return color;
      })()
    JS
  end
end

module PollingHelper
  def wait_for(timeout = Capybara.default_max_wait_time)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until (value = yield)
      raise "Waited #{timeout}s at #{caller_locations(1, 1).first} and the condition never held" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.05
    end
    value
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
  config.include PollingHelper, type: :system
  config.include ComputedColorHelper, type: :system
  config.include FetchStubHelper, type: :system
end
