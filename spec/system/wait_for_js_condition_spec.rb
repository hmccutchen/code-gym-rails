require "rails_helper"

RSpec.describe "wait_for_js_condition", type: :system do
  let(:user) { create_fake_provider_user }

  it "keeps polling when a navigation destroys the context it asked in" do
    visit_as(user)
    wait_for_js

    raised = false
    page.driver.with_playwright_page do |pw|
      allow(pw).to receive(:evaluate).and_wrap_original do |original, *args|
        next (raised = true) && raise(Playwright::Error.new(message: "Execution context was destroyed.")) unless raised

        original.call(*args)
      end
    end

    expect { wait_for_js_condition("true", timeout: 5) }.not_to raise_error
    expect(raised).to be(true)
  end

  it "re-raises an error that is not a navigation" do
    visit_as(user)
    wait_for_js

    page.driver.with_playwright_page do |pw|
      allow(pw).to receive(:evaluate).and_raise(Playwright::Error.new(message: "ReferenceError: nope"))
    end

    expect { wait_for_js_condition("nope", timeout: 5) }.to raise_error(Playwright::Error, /ReferenceError/)
  end

  it "re-raises a closed target rather than polling a page that is gone" do
    visit_as(user)
    wait_for_js

    page.driver.with_playwright_page do |pw|
      allow(pw).to receive(:evaluate).and_raise(Playwright::Error.new(message: "Target closed"))
    end

    expect { wait_for_js_condition("true", timeout: 5) }.to raise_error(Playwright::Error, /Target closed/)
  end
end
