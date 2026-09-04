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
      expect(response.body).to include(setup_path)
    end

    # `AccountsController` skips `require_api_key` on purpose: without that
    # skip a keyless user is bounced to /setup and — with the nav log-out
    # button gone — has no way to log out at all.
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

    # The buttons post the state they want. Read as a flip, a double-tapped
    # Resume would re-read an already-unpaused user and take the pause branch,
    # leaving generation paused by two clicks of a button labelled "Resume".
    it "stays resumed when Resume is double-tapped" do
      user = create_user_with_key(email: "doubletap@example.com", name: "Double")
      user.update!(paused_generation_at: Time.current)
      login_as(user)

      2.times { patch toggle_generation_account_path, params: { paused: "0" } }

      expect(user.reload.paused_generation_at).to be_nil
    end

    # Asserts the timestamp is untouched, not merely still set: it is the floor
    # #held_exercise searches from, so re-stamping it walks that floor past the
    # set the pause stranded.
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
