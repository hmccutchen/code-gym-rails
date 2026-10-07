require "rails_helper"

# A failed request may only put a sentence the app wrote on the page, or the
# page's own wording. The three replies below are the ones that used to leak
# through: a dropped connection rejects with the browser's own text, an
# unhandled exception answers JSON whose `error` is Rails' status phrase, and
# an HTML error page makes JSON parsing throw.
RSpec.describe "Failed requests on the page", type: :system, with_csrf: true do
  FAILED_REPLIES = {
    "a dropped connection" => <<~JS,
      window.fetch = () => Promise.reject(new TypeError("Failed to fetch"));
    JS
    "Rails' reply to an unhandled exception" => <<~JS,
      window.fetch = () => Promise.resolve(new Response(
        JSON.stringify({ status: 500, error: "Internal Server Error" }),
        { status: 500, headers: { "Content-Type": "application/json" } }
      ));
    JS
    "an HTML error page" => <<~JS
      window.fetch = () => Promise.resolve(new Response(
        "<!DOCTYPE html><html><body>We're sorry, but something went wrong.</body></html>",
        { status: 500, headers: { "Content-Type": "text/html" } }
      ));
    JS
  }.freeze

  RAW_TEXT = /Failed to fetch|Internal Server Error|Unexpected token|not valid JSON|\b500\b/

  def open_duck(user)
    visit_with_todays_set(user)
    expect(page).to have_content(/Code Review/i, wait: 10)
    duck = first("[data-duck-thread][data-section='code_review']")
    duck.find(".duck-toggle").click
    duck
  end

  FAILED_REPLIES.each do |name, stub|
    it "shows the thinking partner's own wording after #{name}" do
      user = create_fake_provider_user

      travel_to(a_weekday) do
        duck = open_duck(user)
        page.execute_script(stub)
        duck.find(".duck-input").fill_in(with: "Why does this loop twice?")
        duck.find(".duck-send").click

        expect(duck).to have_content(I18n.t("duck.send_failed"), wait: 10)
        expect(duck.find(".duck-status").text).not_to match(RAW_TEXT)
        expect(duck.find(".duck-send")).not_to be_disabled
      end
    end
  end

  it "still shows the sentence the app wrote when the endpoint refuses" do
    user = create_fake_provider_user

    travel_to(a_weekday) do
      duck = open_duck(user)
      page.execute_script(<<~JS)
        window.fetch = () => Promise.resolve(new Response(
          JSON.stringify({ status: "error", error: "Gemini's daily limit is used up, so the thinking partner didn't answer." }),
          { status: 503, headers: { "Content-Type": "application/json" } }
        ));
      JS
      duck.find(".duck-input").fill_in(with: "Why does this loop twice?")
      duck.find(".duck-send").click

      expect(duck).to have_content("Gemini's daily limit is used up, so the thinking partner didn't answer.", wait: 10)
    end
  end

  it "says the session expired when a request lands on the login page" do
    user = create_fake_provider_user

    travel_to(a_weekday) do
      duck = open_duck(user)
      page.execute_script(<<~JS)
        window.fetch = () => Promise.resolve(Object.defineProperty(
          new Response("<html><body>Log in</body></html>", { status: 200, headers: { "Content-Type": "text/html" } }),
          "redirected", { value: true }
        ));
      JS
      duck.find(".duck-input").fill_in(with: "Why does this loop twice?")
      duck.find(".duck-send").click

      expect(duck).to have_content(I18n.t("server_message.signed_out"), wait: 10)
    end
  end
end
