require "rails_helper"

# with_csrf: the submit action reads the CSRF meta tag, which test config blanks (see spec/support/csrf_helper.rb).
RSpec.describe "Interaction before the deferred modules run", type: :system, with_csrf: true do
  let(:user) { create_fake_provider_user }
  let(:stalled) { { modules: false, controller: nil } }
  let(:errors) { [] }

  before do
    allow_any_instance_of(Propshaft::Server).to receive(:call).and_wrap_original do |original, env|
      path = env["PATH_INFO"].to_s
      module_asset = path.include?("code_gym/") || path.include?("_controller")
      sleep 3 if (stalled[:modules] && path.include?("code_gym/")) || (stalled[:controller] && path.include?(stalled[:controller]))
      status, headers, body = original.call(env)
      headers["cache-control"] = "no-store" if module_asset
      [ status, headers, body ]
    end
  end

  def watch_page_errors
    page.driver.with_playwright_page { |pw| pw.on("pageerror", ->(error) { errors << error.to_s }) }
  end

  def reload_with_modules_stalled
    url = page.current_url
    stalled[:modules] = true

    page.driver.with_playwright_page do |pw|
      pw.goto(url, waitUntil: "commit")
      expect(pw.evaluate("document.readyState")).to eq("interactive")
      yield pw
    end
  end

  # Monotonic, not Time.current: these examples run inside travel_to, where a frozen clock never passes a deadline.
  def wait_for(timeout = 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    sleep 0.1 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
  end

  it "drops a Submit click made while the modules are still loading rather than posting the day" do
    travel_to(a_weekday) do
      watch_page_errors
      visit_with_todays_set(user)
      expect(page).to have_content(/Code Review/i, wait: 10)
      fields = rating_row_fields
      fields.each { |field| fill_in_answer(field, "A substantive answer for #{field} that clears the length floor.") }
      fields.each { |field| rate_section(field) }
      expect_ready_to_submit

      reload_with_modules_stalled do |pw|
        expect(pw.evaluate("document.querySelector('#gym-form') !== null")).to be(true)
        pw.evaluate("[...document.querySelectorAll('button')].find((b) => /Submit answers/i.test(b.textContent)).click()")
      end

      expect(user.daily_responses.sole).not_to be_submitted

      stalled[:modules] = false
      Timeout.timeout(20) { sleep 0.1 until answer_form_connected? }
      click_button "Submit answers"

      expect(page).to have_content("Review ready!", wait: 20)
      expect(user.daily_responses.sole.reload).to be_submitted
      expect(errors).to be_empty
    end
  end

  def answer_form_connected?
    page.evaluate_script(<<~JS)
      !!(window.Stimulus && window.Stimulus.getControllerForElementAndIdentifier(
        document.querySelector('[data-controller~="answer-form"]'), "answer-form"))
    JS
  end

  # Pull-to-refresh reloads once pending() is false, so a typed answer must count before the modules arrive.
  it "counts an answer typed while the modules are still loading as pending, then saves it" do
    answer = "An answer typed before the modules finished loading, long enough to count."

    travel_to(a_weekday) do
      watch_page_errors
      visit_with_todays_set(user)
      expect(page).to have_content(/Code Review/i, wait: 10)

      reload_with_modules_stalled do |pw|
        pending = pw.evaluate(<<~JS)
          (() => {
            const box = document.querySelector('textarea[data-field="code_review"]');
            box.value = #{answer.to_json};
            box.dispatchEvent(new Event("input", { bubbles: true }));
            return window.CodeGymSaveStatus.pending();
          })()
        JS
        expect(pending).to be(true)
      end

      wait_for { user.daily_responses.reload.first&.answers&.dig("code_review") == answer }
      expect(user.daily_responses.sole.answers["code_review"]).to eq(answer)
      expect(errors).to be_empty
    end
  end

  it "keeps an edit pending until the controller that owns it has connected" do
    answer = "An answer typed while that section's own controller was still loading, long enough to count."

    travel_to(a_weekday) do
      watch_page_errors
      visit_with_todays_set(user)
      expect(page).to have_content(/Code Review/i, wait: 10)

      url = page.current_url
      stalled[:controller] = "answer_form_controller"

      page.driver.with_playwright_page do |pw|
        pw.goto(url, waitUntil: "commit")
        unpending_before_connect = pw.evaluate(<<~JS)
          (async () => {
            const box = document.querySelector('textarea[data-field="code_review"]');
            box.value = #{answer.to_json};
            box.dispatchEvent(new Event("input", { bubbles: true }));

            const connected = () => !!(window.Stimulus && window.Stimulus.getControllerForElementAndIdentifier(
              document.querySelector('[data-controller~="answer-form"]'), "answer-form"));

            while (!connected()) {
              if (!window.CodeGymSaveStatus.pending()) return true;
              await new Promise((resume) => setTimeout(resume, 20));
            }

            return false;
          })()
        JS
        expect(unpending_before_connect).to be(false)
      end

      wait_for { user.daily_responses.reload.first&.answers&.dig("code_review") == answer }
      expect(user.daily_responses.sole.answers["code_review"]).to eq(answer)
      expect(errors).to be_empty
    end
  end

  it "counts a slider moved while the modules are still loading as pending, then saves it" do
    watch_page_errors
    visit_as(user)
    visit setup_path
    expect(page).to have_css("#weight-challenge", visible: :all)

    reload_with_modules_stalled do |pw|
      pending = pw.evaluate(<<~JS)
        (() => {
          const slider = document.getElementById("weight-challenge");
          slider.value = "0";
          slider.dispatchEvent(new Event("input", { bubbles: true }));
          return window.CodeGymSaveStatus.pending();
        })()
      JS
      expect(pending).to be(true)
    end

    wait_for { user.reload.section_kind_weights == { "challenge" => 0.25 } }
    expect(user.reload.section_kind_weights).to eq("challenge" => 0.25)
    expect(errors).to be_empty
  end

  it "saves a Setup preference chosen while the modules are still loading" do
    watch_page_errors
    visit_as(user)
    visit setup_path
    expect(page).to have_css("#skill-level")

    reload_with_modules_stalled do |pw|
      pw.evaluate(<<~JS)
        (() => {
          const select = document.getElementById("skill-level");
          select.value = "senior";
          select.dispatchEvent(new Event("change", { bubbles: true }));
        })()
      JS
    end

    wait_for { user.reload.skill_level == "senior" }
    expect(user.reload.skill_level).to eq("senior")
    expect(errors).to be_empty
  end
end
