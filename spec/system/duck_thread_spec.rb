require "rails_helper"

# with_csrf: the script reads the CSRF meta tag, which test config blanks (see spec/support/csrf_helper.rb).
RSpec.describe "Duck thread", type: :system, with_csrf: true do
  def open_duck(user)
    visit_with_todays_set(user)
    expect(page).to have_content(/Code Review/i, wait: 10)

    duck = first(".duck-thread[data-duck-thread-section-value='code_review']")
    duck.find(".duck-toggle").click
    duck
  end

  def ask(duck, text)
    duck.find(".duck-input").fill_in(with: text)
    duck.find(".duck-send").click
  end

  it "answers a question and enforces the cap" do
    user = create_fake_provider_user

    travel_to(a_weekday) do
      duck = open_duck(user)

      expect(duck.find(".duck-toggle")["aria-expanded"]).to eq("true")

      ask(duck, "I don't see what's slow here")

      expect(duck).to have_content(FakeService::DUCK_RESPONSE_TEXT, wait: 10)
      expect(duck).to have_selector(".duck-turn.duck-user", text: "I don't see what's slow here")

      expect(DailyResponse.count).to eq(0)
      expect(page).to have_css(".duck-turn.duck-assistant")

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

  it "sends on Enter without the form navigating away" do
    user = create_fake_provider_user

    travel_to(a_weekday) do
      duck = open_duck(user)
      duck.find(".duck-input").fill_in(with: "why is this slow?")
      duck.find(".duck-input").send_keys(:enter)

      expect(duck).to have_selector(".duck-turn.duck-user", text: "why is this slow?", wait: 10)
      expect(duck).to have_content(FakeService::DUCK_RESPONSE_TEXT, wait: 10)
      expect(page).to have_current_path(root_path)
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

      # Resolve in-page with a canned payload so Clear runs mid-flight deterministically, with no network involved.
      page.execute_script(<<~JS)
        window.__held = [];
        window.__release = () => window.__held.splice(0).forEach((resolve) => resolve(new Response(
          JSON.stringify({ status: "ok", answer: "RELEASED-ANSWER", version: 1 }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )));
        window.fetch = () => new Promise((resolve) => window.__held.push(resolve));
      JS

      ask(duck, "hold this one open")
      expect(duck).to have_content("Thinking…", wait: 10)

      duck.find(".duck-clear").click
      expect(duck).to have_no_css(".duck-turn")

      page.execute_script("window.__release();")

      # A bare negative matcher would pass before the continuation ran, and keep passing with the guard removed.
      sleep 1

      expect(page.evaluate_script("document.querySelectorAll('.duck-turn').length")).to eq(0)
      expect(duck).to have_no_content("RELEASED-ANSWER")
      expect(duck.find(".duck-send")).not_to be_disabled
      expect(duck.find(".duck-input")).not_to be_disabled
    end
  end

  def reopen_duck
    visit root_path
    expect(page).to have_content(/Code Review/i, wait: 10)
    duck = first(".duck-thread[data-duck-thread-section-value='code_review']")
    duck.find(".duck-toggle").click
    duck
  end

  it "restores the thread after a reload, and the duck still answers from it" do
    user = create_fake_provider_user

    travel_to(a_weekday) do
      ask(open_duck(user), "before the reload")
      expect(page).to have_css(".duck-turn.duck-assistant", count: 1, wait: 10)

      duck = reopen_duck
      expect(duck).to have_css(".duck-turn.duck-user", text: "before the reload")
      expect(duck).to have_css(".duck-turn.duck-assistant", text: FakeService::DUCK_RESPONSE_TEXT)

      ask(duck, "after the reload")
      expect(duck).to have_css(".duck-turn.duck-user", count: 2, wait: 10)
      expect(duck).to have_no_content(/out of step/i)
    end
  end

  it "keeps the cap across a reload, and Clear still gives it back" do
    user = create_fake_provider_user

    travel_to(a_weekday) do
      duck = open_duck(user)
      ResponsesController::MAX_DUCK_TURNS_PER_SECTION.times do |i|
        ask(duck, "stuck #{i}")
        expect(duck).to have_css(".duck-turn.duck-user", count: i + 1, wait: 10)
      end

      duck = reopen_duck
      expect(duck).to have_content(/used all #{ResponsesController::MAX_DUCK_TURNS_PER_SECTION} messages/i)
      expect(duck.find(".duck-send")).to be_disabled

      duck.find(".duck-clear").click
      expect(duck.find(".duck-send")).not_to be_disabled
      ask(duck, "a fresh start")
      expect(duck).to have_css(".duck-turn.duck-user", count: 1, wait: 10)
      expect(duck).to have_content(FakeService::DUCK_RESPONSE_TEXT)
    end
  end

  it "keeps a cleared thread cleared after a reload, and answers the next message" do
    user = create_fake_provider_user

    travel_to(a_weekday) do
      duck = open_duck(user)
      ask(duck, "soon cleared")
      expect(duck).to have_css(".duck-turn.duck-assistant", count: 1, wait: 10)

      duck.find(".duck-clear").click
      cleared = -> { DuckThread.first.reload.stored_turns("code_review").empty? }
      50.times { cleared.call ? break : sleep(0.2) }
      expect(cleared.call).to be(true)

      duck = reopen_duck
      expect(duck).to have_no_css(".duck-turn")

      ask(duck, "after clearing and reloading")
      expect(duck).to have_css(".duck-turn.duck-assistant", text: FakeService::DUCK_RESPONSE_TEXT, wait: 10)
      expect(duck).to have_no_content(/out of step/i)
    end
  end

  it "sends one Clear for a double click, and the next message is answered" do
    user = create_fake_provider_user

    travel_to(a_weekday) do
      duck = open_duck(user)
      ask(duck, "soon cleared twice")
      expect(duck).to have_css(".duck-turn.duck-assistant", count: 1, wait: 10)

      page.execute_script(<<~JS)
        const originalFetch = window.fetch;
        window.__deletes = 0;
        window.__held = [];
        window.__release = () => window.__held.splice(0).forEach((go) => go());
        window.fetch = (url, options) => {
          if (options?.method !== "DELETE") return originalFetch(url, options);
          window.__deletes++;
          return new Promise((resolve) => window.__held.push(() => resolve(originalFetch(url, options))));
        };
      JS
      duck.find(".duck-clear").click
      duck.find(".duck-clear").click
      expect(page.evaluate_script("window.__deletes")).to eq(1)
      page.execute_script("window.__release()")

      ask(duck, "after a double clear")
      expect(duck).to have_css(".duck-turn.duck-assistant", text: FakeService::DUCK_RESPONSE_TEXT, wait: 10)
      expect(duck).to have_no_content(/out of step/i)
      expect(page.evaluate_script("window.__deletes")).to eq(1)
    end
  end

  it "puts the thread back when Clear can't reach the server" do
    user = create_fake_provider_user

    travel_to(a_weekday) do
      duck = open_duck(user)
      ask(duck, "kept on a failed clear")
      expect(duck).to have_css(".duck-turn.duck-assistant", count: 1, wait: 10)

      page.execute_script(<<~JS)
        const originalFetch = window.fetch;
        window.fetch = (url, options) => options?.method === "DELETE"
          ? Promise.reject(new TypeError("offline"))
          : originalFetch(url, options);
      JS
      duck.find(".duck-clear").click

      expect(duck).to have_css(".duck-turn.duck-user", text: "kept on a failed clear", wait: 10)
      expect(duck).to have_content(I18n.t("duck.send_failed"))
      expect(DuckThread.first.reload.user_turn_count("code_review")).to eq(1)
    end
  end

  [ [ "the reply returns first", %w[ask delete] ], [ "the Clear fails first", %w[delete ask] ] ].each do |order_name, order|
    it "keeps the in-flight reply when Clear can't reach the server and #{order_name}" do
      user = create_fake_provider_user

      travel_to(a_weekday) do
        duck = open_duck(user)
        page.execute_script(<<~JS)
          window.__originalFetch = window.fetch;
          window.__held = {};
          window.fetch = (url, options) => {
            if (options?.method === "DELETE") {
              return new Promise((_, reject) => { window.__held.delete = () => reject(new TypeError("offline")); });
            }
            if (options?.method === "POST" && String(url).includes("duck_thread")) {
              return new Promise((resolve) => { window.__held.ask = () => resolve(window.__originalFetch(url, options)); });
            }
            return window.__originalFetch(url, options);
          };
        JS

        ask(duck, "sent before the clear")
        expect(duck).to have_content("Thinking…", wait: 10)
        duck.find(".duck-clear").click
        order.each do |kind|
          page.execute_script("window.__held['#{kind}']()")
          sleep 0.5
        end

        expect(duck).to have_css(".duck-turn.duck-user", text: "sent before the clear", wait: 10)
        expect(duck).to have_css(".duck-turn.duck-assistant", text: FakeService::DUCK_RESPONSE_TEXT)

        page.execute_script("window.fetch = window.__originalFetch")
        ask(duck, "the next message")
        expect(duck).to have_css(".duck-turn.duck-user", count: 2, wait: 10)
        expect(duck).to have_no_content(/out of date|out of step/i)
      end
    end
  end

  it "surfaces a server-side rejection as a status message instead of a broken page" do
    user = create_fake_provider_user

    travel_to(a_weekday) do
      duck = open_duck(user)
      # A real 422 from the endpoint: rspec-mocks stubs don't reach the server thread handling the driver's requests.
      ask(duck, "x" * (ResponsesController::MAX_DUCK_MESSAGE_LENGTH + 1))

      expect(duck).to have_content(/too long/i, wait: 10)
      expect(duck.find(".duck-send")).not_to be_disabled
      expect(duck).to have_no_css(".duck-turn")
    end
  end

  it "sends the pre-written explanation request with an empty input box, the usual state for someone stuck" do
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

  it "disables Explain at the cap rather than letting it fail silently" do
    user = create_fake_provider_user

    travel_to(a_weekday) do
      duck = open_duck(user)

      ResponsesController::MAX_DUCK_TURNS_PER_SECTION.times do |i|
        ask(duck, "stuck #{i}")
        expect(duck).to have_css(".duck-turn.duck-user", count: i + 1, wait: 10)
      end

      # Not clicked: Playwright would wait for a disabled button to become actionable and time out.
      expect(duck.find(".duck-explain")).to be_disabled
      expect(duck.find(".duck-send")).to be_disabled
      expect(duck.find(".duck-input")).to be_disabled

      duck.find(".duck-clear").click
      expect(duck.find(".duck-explain")).not_to be_disabled
    end
  end

  it "does not render the duck thread once the set is submitted" do
    user = create_fake_provider_user

    travel_to(a_weekday) do
      visit_with_todays_set(user)
      expect(page).to have_content(/Code Review/i, wait: 10)

      find(%(textarea[data-field="code_review"])).fill_in(
        with: "It re-runs the loyalty_tier query inside the loop — precompute it once outside."
      )
      rate_all_sections
      click_button "Submit answers"

      expect(page).to have_content("Review ready!", wait: 10)

      expect(page).to have_content("✓ Submitted")
      expect(page).to have_no_css(".duck-thread")
    end
  end
end
