require "rails_helper"

RSpec.describe "Accounts", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  describe "GET /account" do
    it "shows the identity summary, log out control and settings link" do
      user = create_user_with_key(email: "dev@example.com", name: "Dev")
      login_as(user)

      get account_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("dev@example.com")
      expect(response.body).to include("Log out")
    end

    it "links the shared phone stylesheet" do
      login_as(create_user_with_key(email: "dev@example.com", name: "Dev"))

      get account_path

      expect(Nokogiri::HTML(response.body).css("head link[rel=stylesheet]").map { |link| link["href"] })
        .to include(a_string_matching(%r{/assets/phone_cards(-\h+)?\.css}))
    end

    it "reaches Settings from the nav, not from the Account page itself" do
      login_as(create_user_with_key(email: "dev@example.com", name: "Dev"))

      get account_path

      page = Nokogiri::HTML(response.body)
      expect(page.css("nav .nav-links a").map { |link| [ link.text, link["href"] ] }).to include([ "Settings", setup_path ])
      expect(page.css("main a[href='#{setup_path}']")).to be_empty
    end

    # Without that skip a keyless user is bounced to /setup and cannot log out.
    it "renders for a user who has not added an API key yet" do
      user = User.create!(email: "keyless@example.com", name: "Keyless")
      login_as(user)

      get account_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("keyless@example.com")
    end

    it "redirects to login when logged out" do
      get account_path

      expect(response).to redirect_to(login_path)
    end
  end

  describe "nav" do
    it "links to the account page instead of showing a log out button" do
      login_as(create_user_with_key)

      get history_path

      expect(response.body).to include(account_path)
      expect(response.body).to include("Account")
    end
  end

  describe "DELETE /account" do
    it "anonymizes the user, clears the session and redirects to login" do
      user = create_user_with_key(email: "leaving@example.com", name: "Leaving")
      login_as(user)

      delete account_path

      expect(response).to redirect_to(login_path)
      follow_redirect!
      expect(response.body).to include("Your account has been deleted.")

      user.reload
      expect(user).to be_anonymized
      expect(user.email).to eq("deleted-user-#{user.id}@anonymized.local")
      expect(user.api_key).to be_nil

      # Session is gone: a follow-up request is no longer authenticated.
      get history_path
      expect(response).to redirect_to(login_path)
    end

    it "does nothing when logged out" do
      user = create_user_with_key(email: "safe@example.com")

      delete account_path

      expect(response).to redirect_to(login_path)
      expect(user.reload).not_to be_anonymized
    end

    it "is a safe redirect, not an error, when submitted twice" do
      user = create_user_with_key(email: "twice@example.com")
      login_as(user)

      delete account_path
      first_stamp = user.reload.anonymized_at

      delete account_path

      expect(response).to redirect_to(login_path)
      expect(user.reload.anonymized_at).to eq(first_stamp)
    end
  end

  describe "API usage" do
    def usage(user, **attrs)
      ApiUsage.create!({ user: user, purpose: "review_response", date: Date.current, provider: "anthropic",
                         tokens_in: 0, tokens_out: 0, cost_usd: nil }.merge(attrs))
    end

    def card
      Nokogiri::HTML(response.body).at_css(".api-usage")
    end

    def rows
      card.css(".api-usage-row").map { |r| [ r.at_css("dt").text.strip, r.at_css("dd").text.strip ] }
    end

    it "shows this month's own-key spend, projection and rows in the user's zone" do
      travel_to Time.utc(2026, 10, 18, 12) do
        user = create_user_with_key(time_zone: "America/New_York")
        usage(user, cost_usd: "1.50")
        usage(user, cost_usd: "0.90")
        usage(user, failure: "timeout")
        usage(user, provider: "gemini", created_at: Time.utc(2026, 10, 1, 4, 30))
        usage(user, cost_usd: "99", created_at: Time.utc(2026, 10, 1, 3, 59))
        usage(user, cost_usd: "99", house_key: true)
        login_as(user)

        get account_path

        expect(card.at_css(".api-usage-label").text.strip).to eq("Spent in October")
        expect(card.at_css(".api-usage-total").text.strip).to eq("$2.40")
        expect(card.at_css(".api-usage-projected")).to be_nil
        expect(rows).to eq([ [ "Claude", "$2.40" ], [ "Gemini", "1 request · not priced" ] ])
        expect(card.at_css(".api-usage-unpriced").text.strip).to eq("2 requests aren't priced.")
        expect(card.at_css(".api-usage-note").text.strip).to eq("Estimated from list prices. Your provider's console shows the exact bill.")
        expect(card.css("table")).to be_empty
        expect(card.css("p:not(.api-usage-total)").map { |p| p["class"].split }).to all(include("card-note"))
      end
    end

    it "shows the projection when every provider has priced spend" do
      travel_to Time.utc(2026, 10, 18, 12) do
        user = create_user_with_key(time_zone: "America/New_York")
        usage(user, cost_usd: "1.50")
        usage(user, cost_usd: "0.90")
        usage(user, failure: "timeout")
        login_as(user)

        get account_path

        expect(card.at_css(".api-usage-projected").text.strip).to eq("On pace for about $4.40 this month")
        expect(card.at_css(".api-usage-unpriced").text.strip).to eq("1 request isn't priced.")
      end
    end

    it "holds the projection back while generation is paused" do
      travel_to Time.utc(2026, 10, 18, 12) do
        user = create_user_with_key(time_zone: "America/New_York")
        user.update!(paused_generation_at: Time.current)
        usage(user, cost_usd: "1.50")
        login_as(user)

        get account_path

        expect(card.at_css(".api-usage-total").text.strip).to eq("$1.50")
        expect(card.at_css(".api-usage-projected")).to be_nil
      end
    end

    it "shows only counts when nothing this month is priced" do
      user = create_user_with_key
      2.times { usage(user, provider: "gemini") }
      login_as(user)

      get account_path

      expect(card.at_css(".api-usage-total")).to be_nil
      expect(card.at_css(".api-usage-projected")).to be_nil
      expect(card.at_css(".api-usage-unpriced")).to be_nil
      expect(rows).to eq([ [ "Gemini", "2 requests · not priced" ] ])
      expect(card.at_css(".api-usage-note")).to be_present
    end

    it "holds the projection back on the first three days" do
      travel_to Time.utc(2026, 10, 2, 16) do
        user = create_user_with_key
        usage(user, cost_usd: "0.30")
        login_as(user)

        get account_path

        expect(card.at_css(".api-usage-total").text.strip).to eq("$0.30")
        expect(card.at_css(".api-usage-projected")).to be_nil
      end
    end

    it "keeps the last evening of the month in that month for a zone behind UTC" do
      travel_to Time.utc(2026, 11, 1, 9, 30) do
        user = create_user_with_key(time_zone: "Pacific/Honolulu")
        usage(user, cost_usd: "1.00")
        login_as(user)

        get account_path

        expect(card.at_css(".api-usage-label").text.strip).to eq("Spent in October")
        expect(card.at_css(".api-usage-projected").text.strip).to eq("On pace for about $1.00 this month")
      end
    end

    it "says so when the key has sent nothing this month" do
      login_as(create_user_with_key)

      get account_path

      expect(card.text).to include("No requests")
      expect(card.css(".api-usage-row")).to be_empty
    end
  end

  describe "card order" do
    def card_headings
      Nokogiri::HTML(response.body).css("main .phone-page > .card").map { |card| card.at_css("h2")&.text&.strip }
    end

    it "orders the cards identity, practice, reminders, security, usage, session, danger" do
      with_push_credentials do
        login_as(create_user_with_key(email: "dev@example.com", name: "Dev"))

        get account_path

        expect(card_headings).to eq([ nil, "Daily practice", "Reminders", "Authenticator app", "AI usage", "Session", "Danger zone" ])
      end
    end

    it "leaves the Reminders card out when push isn't configured" do
      without_push_credentials do
        login_as(create_user_with_key(email: "dev@example.com", name: "Dev"))

        get account_path

        expect(card_headings).to eq([ nil, "Daily practice", "Authenticator app", "AI usage", "Session", "Danger zone" ])
      end
    end

    it "styles the reminders offer's status line as a card note" do
      with_push_credentials do
        login_as(create_user_with_key(email: "dev@example.com", name: "Dev"))

        get account_path

        expect(Nokogiri::HTML(response.body).at_css("#push-status")["class"].split).to include("card-note")
      end
    end

    it "renders the nudges switch with no Save button except inside noscript" do
      with_push_credentials do
        user = create_user_with_key.tap { |u| u.update!(reminder_level: :ready) }
        login_as(user)
        get account_path

        form = Nokogiri::HTML(response.body).at_css("form[data-controller='save-switch']")
        expect(form["data-save-switch-url-value"]).to eq(push_subscription_path)
        expect(form["data-save-switch-key-value"]).to eq("nudges")
        expect(form["data-save-switch-field-value"]).to eq("nudges")
        expect(form.css("button[type=submit]").reject { |b| b.ancestors("noscript").any? }).to be_empty
        expect(form.at_css("noscript")).to be_present
        expect(form.at_css("p.switch-status[role=status]").text).to eq("")
      end
    end

    it "puts Log out in the Session card as a full-width button" do
      login_as(create_user_with_key(email: "dev@example.com", name: "Dev"))

      get account_path

      session_card = Nokogiri::HTML(response.body).css("main .card").find { |card| card.at_css("h2")&.text == "Session" }
      expect(session_card.at_css("form[action='#{logout_path}'] button.btn-block").text).to eq("Log out")
    end
  end

  describe "the danger zone" do
    it "renders the delete control and the confirmation copy" do
      login_as(create_user_with_key)

      get account_path

      expect(response.body).to include("Danger zone")
      expect(response.body).to include("Delete my account")
      expect(response.body).to include("It cannot be undone.")
    end
  end

  describe "the automatic generation toggle" do
    it "shows the active state and a pause button when not paused" do
      login_as(create_user_with_key)

      get account_path

      expect(response.body).to include("Automatic generation is active")
      expect(response.body).to include("Pause automatic generation")
    end

    it "shows the paused state and a resume button when paused" do
      user = create_user_with_key(email: "paused@example.com", name: "Paused")
      user.update!(paused_generation_at: Time.utc(2026, 7, 29, 12, 0))
      login_as(user)

      get account_path

      expect(response.body).to include("Automatic generation is paused (since July 29)")
      expect(response.body).to include("Resume automatic generation")
    end
  end

  describe "PATCH /account/toggle_generation" do
    it "pauses automatic generation for an active user" do
      user = create_user_with_key(email: "pauser@example.com", name: "Pauser")
      login_as(user)

      patch toggle_generation_account_path

      expect(response).to redirect_to(account_path)
      follow_redirect!
      expect(response.body).to include("Automatic daily generation paused.")
      expect(user.reload.paused_generation_at).not_to be_nil
    end

    it "resumes automatic generation for a paused user" do
      user = create_user_with_key(email: "resumer@example.com", name: "Resumer")
      user.update!(paused_generation_at: Time.current)
      login_as(user)

      patch toggle_generation_account_path

      expect(response).to redirect_to(account_path)
      follow_redirect!
      expect(response.body).to include("Automatic daily generation resumed.")
      expect(user.reload.paused_generation_at).to be_nil
    end

    it "brings the held set forward to today and says so" do
      travel_to(Time.utc(2026, 7, 22, 12)) do
        user = create_user_with_key(email: "held@example.com", name: "Held")
        held = user.daily_exercises.create!(date: Date.current - 1, generated_at: Time.current,
                                            problem_set: { "code_review" => { "question" => "q" } })
        user.update!(paused_generation_at: (Date.current - 1).in_time_zone(user.effective_time_zone) + 9.hours)
        login_as(user)

        patch toggle_generation_account_path

        follow_redirect!
        expect(response.body).to include("The set you had waiting is on your dashboard.")
        expect(held.reload.date).to eq(Date.current)
      end
    end

    # Read as a flip, a double-tapped Resume would pause generation again.
    it "stays resumed when Resume is double-tapped" do
      user = create_user_with_key(email: "doubletap@example.com", name: "Double")
      user.update!(paused_generation_at: Time.current)
      login_as(user)

      2.times { patch toggle_generation_account_path, params: { paused: "0" } }

      expect(user.reload.paused_generation_at).to be_nil
    end

    # The pause timestamp is #held_exercise's floor, so re-stamping it would strand the held set.
    it "stays paused when Pause is double-tapped, without restamping the pause" do
      user = create_user_with_key(email: "doubletap2@example.com", name: "Double Two")
      paused_at = 2.days.ago.change(usec: 0)
      user.update!(paused_generation_at: paused_at)
      login_as(user)

      2.times { patch toggle_generation_account_path, params: { paused: "1" } }

      expect(user.reload.paused_generation_at).to be_within(1.second).of(paused_at)
    end

    it "still recovers the held set after a repeated Pause from a stale tab" do
      travel_to(Time.utc(2026, 7, 22, 12)) do
        user = create_user_with_key(email: "stale-tab@example.com", name: "Stale")
        held = user.daily_exercises.create!(date: Date.current - 1, generated_at: Time.current,
                                            problem_set: { "code_review" => { "question" => "q" } })
        user.update!(paused_generation_at: (Date.current - 1).in_time_zone(user.effective_time_zone) + 9.hours)
        login_as(user)

        patch toggle_generation_account_path, params: { paused: "1" } # stale tab re-pauses
        patch toggle_generation_account_path, params: { paused: "0" }

        expect(held.reload.date).to eq(Date.current)
        expect(user.reload.paused_generation_at).to be_nil
      end
    end

    it "does nothing when logged out" do
      user = create_user_with_key(email: "loggedout@example.com")

      patch toggle_generation_account_path

      expect(response).to redirect_to(login_path)
      expect(user.reload.paused_generation_at).to be_nil
    end
  end
end
