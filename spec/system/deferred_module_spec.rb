require "rails_helper"

# with_csrf: the submit script reads the CSRF meta tag, which test config blanks (see spec/support/csrf_helper.rb).
RSpec.describe "Interaction before the deferred modules run", type: :system, with_csrf: true do
  it "holds a Submit click made while the modules are still loading, then completes it" do
    user = create_fake_provider_user
    stalled = { modules: false }
    errors = []

    allow_any_instance_of(Propshaft::Server).to receive(:call).and_wrap_original do |original, env|
      module_asset = env["PATH_INFO"].to_s.include?("code_gym/")
      sleep 3 if stalled[:modules] && module_asset
      status, headers, body = original.call(env)
      headers["cache-control"] = "no-store" if module_asset
      [ status, headers, body ]
    end

    travel_to(a_weekday) do
      page.driver.with_playwright_page { |pw| pw.on("pageerror", ->(error) { errors << error.to_s }) }

      visit_with_todays_set(user)
      expect(page).to have_content(/Code Review/i, wait: 10)
      fields = rating_row_fields
      fields.each { |field| fill_in_answer(field, "A substantive answer for #{field} that clears the length floor.") }
      fields.each { |field| rate_section(field) }
      expect_ready_to_submit

      url = page.current_url
      stalled[:modules] = true

      page.driver.with_playwright_page do |pw|
        pw.goto(url, waitUntil: "commit")
        expect(pw.evaluate("document.readyState")).to eq("interactive")
        pw.evaluate("[...document.querySelectorAll('button')].find((b) => /Submit answers/i.test(b.textContent)).click()")
      end

      expect(page).to have_content("Review ready!", wait: 20)
      expect(user.daily_responses.sole).to be_submitted
      expect(errors).to be_empty
    end
  end
end
