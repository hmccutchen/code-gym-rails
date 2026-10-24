require "rails_helper"

# The three replies that used to leak: the browser's dropped-connection text, Rails' status phrase, an HTML error page.
RSpec.describe "Failed requests on the page", type: :system, with_csrf: true do
  FAILED_REPLIES = {
    "a dropped connection" => FetchStubHelper::OFFLINE_REPLY,
    "Rails' reply to an unhandled exception" => <<~JS,
      Promise.resolve(new Response(
        JSON.stringify({ status: 500, error: "Internal Server Error" }),
        { status: 500, headers: { "Content-Type": "application/json" } }
      ))
    JS
    "an HTML error page" => <<~JS
      Promise.resolve(new Response(
        "<!DOCTYPE html><html><body>We're sorry, but something went wrong.</body></html>",
        { status: 500, headers: { "Content-Type": "text/html" } }
      ))
    JS
  }.freeze

  RAW_TEXT = /Failed to fetch|Internal Server Error|Unexpected token|not valid JSON|\b500\b/

  def open_duck(user)
    visit_with_todays_set(user)
    expect(page).to have_content(/Code Review/i)
    duck = first(".duck-thread[data-duck-thread-section-value='code_review']")
    duck.find(".duck-toggle").click
    duck
  end

  FAILED_REPLIES.each do |name, reply|
    it "shows the thinking partner's own wording after #{name}" do
      user = create_fake_provider_user

      travel_to(a_weekday) do
        duck = open_duck(user)
        stub_fetch(duck_thread_responses_path, reply)
        duck.find(".duck-input").fill_in(with: "Why does this loop twice?")
        duck.find(".duck-send").click

        expect(duck).to have_content(I18n.t("duck.send_failed"))
        expect(duck.find(".duck-status").text).not_to match(RAW_TEXT)
        expect(duck.find(".duck-send")).not_to be_disabled
      end
    end
  end

  it "still shows the sentence the app wrote when the endpoint refuses" do
    user = create_fake_provider_user

    travel_to(a_weekday) do
      duck = open_duck(user)
      stub_fetch(duck_thread_responses_path, <<~JS)
        Promise.resolve(new Response(
          JSON.stringify({ status: "error", error: "Gemini's daily limit is used up, so the thinking partner didn't answer." }),
          { status: 503, headers: { "Content-Type": "application/json" } }
        ))
      JS
      duck.find(".duck-input").fill_in(with: "Why does this loop twice?")
      duck.find(".duck-send").click

      expect(duck).to have_content("Gemini's daily limit is used up, so the thinking partner didn't answer.")
    end
  end

  it "says the session expired when a request lands on the login page" do
    user = create_fake_provider_user

    travel_to(a_weekday) do
      duck = open_duck(user)
      redirect_requests_to_login(duck_thread_responses_path)
      duck.find(".duck-input").fill_in(with: "Why does this loop twice?")
      duck.find(".duck-send").click

      expect(duck).to have_content(I18n.t("request.signed_out"))
    end
  end
end
