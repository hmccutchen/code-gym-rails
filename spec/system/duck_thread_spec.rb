require "rails_helper"

# The duck thread is entirely inline JavaScript talking to a JSON endpoint, so
# request specs execute none of it. These cover the parts that only exist in
# the browser: the toggle, the fetch round trip, the in-memory (never
# persisted) thread, the client-side turn cap, and Clear.
RSpec.describe "Duck thread", type: :system, with_csrf: true do
  # The inline script reads the CSRF meta tag before every fetch, and
  # allow_forgery_protection off (config/environments/test.rb) blanks it.
  # See spec/support/csrf_helper.rb.

  def open_duck(user)
    perform_enqueued_jobs { visit_as(user) }
    expect(page).to have_content(/Code Review/i, wait: 10)

    duck = first("[data-duck-thread][data-section='code_review']")
    duck.find(".duck-toggle").click
    duck
  end

  def ask(duck, text)
    duck.find(".duck-input").fill_in(with: text)
    duck.find(".duck-send").click
  end

  it "answers a question, keeps the thread client-side, and enforces the cap" do
    user = create_fake_provider_user

    travel_to(a_weekday) do
      duck = open_duck(user)

      expect(duck.find(".duck-toggle")["aria-expanded"]).to eq("true")

      ask(duck, "I don't see what's slow here")

      expect(duck).to have_content(FakeService::DUCK_RESPONSE_TEXT, wait: 10)
      expect(duck).to have_selector(".duck-turn.duck-user", text: "I don't see what's slow here")

      # Never persisted: the conversation exists only in this tab.
      expect(DailyResponse.count).to eq(0)
      expect(page).to have_css(".duck-turn.duck-assistant")

      # The input clears and stays usable below the cap.
      expect(duck.find(".duck-input").value).to eq("")

      (ResponsesController::MAX_DUCK_TURNS_PER_SECTION - 1).times do |i|
        ask(duck, "still stuck #{i}")
        expect(duck).to have_css(".duck-turn.duck-user", count: i + 2, wait: 10)
      end

      expect(duck).to have_content(/used all #{ResponsesController::MAX_DUCK_TURNS_PER_SECTION} messages/i, wait: 10)
      expect(duck.find(".duck-send")).to be_disabled
      expect(duck.find(".duck-input")).to be_disabled
    end
  end

  it "labels each turn's speaker for assistive tech, not just by colour" do
    user = create_fake_provider_user

    travel_to(a_weekday) do
      duck = open_duck(user)
      ask(duck, "what should I look at first?")
      expect(duck).to have_content(FakeService::DUCK_RESPONSE_TEXT, wait: 10)

      expect(duck.find(".duck-turn.duck-user", match: :first).text(:all)).to start_with("You:")
      expect(duck.find(".duck-turn.duck-assistant", match: :first).text(:all)).to start_with("Duck:")
    end
  end

  it "Clear empties the transcript and restores the input past the cap" do
    user = create_fake_provider_user

    travel_to(a_weekday) do
      duck = open_duck(user)
      ask(duck, "a first question")
      expect(duck).to have_content(FakeService::DUCK_RESPONSE_TEXT, wait: 10)

      duck.find(".duck-clear").click

      expect(duck).to have_no_css(".duck-turn")
      expect(duck.find(".duck-send")).not_to be_disabled
      expect(duck.find(".duck-input")).not_to be_disabled
    end
  end

  it "drops a reply whose conversation was cleared while the request was in flight" do
    user = create_fake_provider_user

    travel_to(a_weekday) do
      duck = open_duck(user)

      # Hold the response open so Clear can run mid-flight, then release it
      # with a canned payload. Resolving in-page (rather than letting the real
      # request through) keeps this deterministic: no network is involved, so
      # the app's continuation runs on the very next microtask.
      page.execute_script(<<~JS)
        window.__release = null;
        window.fetch = () => new Promise((resolve) => {
          window.__release = () => resolve(new Response(
            JSON.stringify({ status: "ok", answer: "RELEASED-ANSWER" }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          ));
        });
      JS

      ask(duck, "hold this one open")
      expect(duck).to have_content("Thinking…", wait: 10)

      duck.find(".duck-clear").click
      expect(duck).to have_no_css(".duck-turn")

      page.execute_script("window.__release();")

      # Give the resolved reply every chance to land before asserting it
      # didn't: a bare negative matcher would pass instantly, before the
      # continuation had run at all, and would keep passing with the guard
      # removed.
      sleep 1

      expect(page.evaluate_script("document.querySelectorAll('.duck-turn').length")).to eq(0)
      expect(duck).to have_no_content("RELEASED-ANSWER")
      expect(duck.find(".duck-send")).not_to be_disabled
      expect(duck.find(".duck-input")).not_to be_disabled
    end
  end

  it "surfaces a server-side rejection as a status message instead of a broken page" do
    user = create_fake_provider_user

    travel_to(a_weekday) do
      duck = open_duck(user)
      # A real 422 from the endpoint (over the message length bound), rather
      # than a stubbed provider — rspec-mocks stubs set here don't reach the
      # server thread the driver's requests are handled on.
      ask(duck, "x" * (ResponsesController::MAX_DUCK_MESSAGE_LENGTH + 1))

      expect(duck).to have_content(/too long/i, wait: 10)
      # Recoverable: the input comes back so the user can retry.
      expect(duck.find(".duck-send")).not_to be_disabled
      expect(duck).to have_no_css(".duck-turn")
    end
  end

  # A user reaches for Explain precisely because they don't know what to type,
  # so the empty input box is the normal case, not an edge case.
  it "sends the pre-written explanation request with an empty input box" do
    user = create_fake_provider_user

    travel_to(a_weekday) do
      duck = open_duck(user)

      expect(duck.find(".duck-input").value).to eq("")
      duck.find(".duck-explain").click

      expect(duck).to have_selector(".duck-turn.duck-user", text: AiService::DUCK_EXPLAIN_REQUEST, wait: 10)
      expect(duck).to have_content(FakeService::DUCK_RESPONSE_TEXT, wait: 10)
      expect(DailyResponse.count).to eq(0)
    end
  end

  # A button that looks live and silently swallows the click is worse than one
  # that is plainly unavailable.
  it "disables Explain at the cap rather than letting it fail silently" do
    user = create_fake_provider_user

    travel_to(a_weekday) do
      duck = open_duck(user)

      ResponsesController::MAX_DUCK_TURNS_PER_SECTION.times do |i|
        ask(duck, "stuck #{i}")
        expect(duck).to have_css(".duck-turn.duck-user", count: i + 1, wait: 10)
      end

      expect(duck.find(".duck-explain")).to be_disabled
      expect(duck.find(".duck-send")).to be_disabled
      expect(duck.find(".duck-input")).to be_disabled

      # Deliberately not clicked: Playwright's click auto-waits for the element
      # to become actionable and would time out on a disabled button rather
      # than reporting the no-op this asserts. "Visibly unavailable" is the
      # whole property — the click itself is covered in manual verification.

      # Clear restores it along with the rest of the controls.
      duck.find(".duck-clear").click
      expect(duck.find(".duck-explain")).not_to be_disabled
    end
  end

  it "does not render the duck thread once the set is submitted" do
    user = create_fake_provider_user

    travel_to(a_weekday) do
      perform_enqueued_jobs { visit_as(user) }
      expect(page).to have_content(/Code Review/i, wait: 10)

      find(%(textarea[data-field="code_review"])).fill_in(
        with: "It re-runs the loyalty_tier query inside the loop — precompute it once outside."
      )
      rate_all_sections
      click_button "Submit answers →"

      # Submitting chains into the review, which lands back on the dashboard's
      # submitted state — where the duck thread must no longer be offered.
      expect(page).to have_content("Review ready!", wait: 10)

      expect(page).to have_content("✓ Submitted")
      expect(page).to have_no_css("[data-duck-thread]")
    end
  end
end
