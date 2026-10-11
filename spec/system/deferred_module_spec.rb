require "rails_helper"

# with_csrf: the submit script reads the CSRF meta tag, which test config blanks (see spec/support/csrf_helper.rb).
RSpec.describe "Interaction before the deferred modules run", type: :system, with_csrf: true do
  let(:user) { create_fake_provider_user }
  let(:stalled) { { modules: false } }
  let(:errors) { [] }

  before do
    allow_any_instance_of(Propshaft::Server).to receive(:call).and_wrap_original do |original, env|
      module_asset = env["PATH_INFO"].to_s.include?("code_gym/")
      sleep 3 if stalled[:modules] && module_asset
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

  def wait_for(timeout = 10)
    deadline = Time.current + timeout
    sleep 0.1 until yield || Time.current > deadline
  end

  it "holds a Submit click made while the modules are still loading, then completes it" do
    travel_to(a_weekday) do
      watch_page_errors
      visit_with_todays_set(user)
      expect(page).to have_content(/Code Review/i, wait: 10)
      fields = rating_row_fields
      fields.each { |field| fill_in_answer(field, "A substantive answer for #{field} that clears the length floor.") }
      fields.each { |field| rate_section(field) }
      expect_ready_to_submit

      reload_with_modules_stalled do |pw|
        pw.evaluate("[...document.querySelectorAll('button')].find((b) => /Submit answers/i.test(b.textContent)).click()")
      end

      expect(page).to have_content("Review ready!", wait: 20)
      expect(user.daily_responses.sole).to be_submitted
      expect(errors).to be_empty
    end
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
end
