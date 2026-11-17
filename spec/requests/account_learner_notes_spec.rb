require "rails_helper"

RSpec.describe "The Learner notes setting on the Account page", type: :request do
  let(:user) { create_user_with_key(email: "notes-setting@example.com") }

  def setting_section = Nokogiri::HTML(response.body).at_css("#learner-notes-setting")

  context "with LEARNER_NOTES on" do
    before { stub_env("LEARNER_NOTES" => "1") }

    it "is off by default and offered to an account on its own key" do
      login_as(user)

      get account_path

      expect(user.reload.learner_notes_enabled).to be(false)
      expect(setting_section.text).to include("Learner notes: off")
      expect(setting_section.at_css("form[action='#{learner_notes_account_path}'] input[name=enabled][value='1']")).to be_present
    end

    it "turns the setting on and off by the state the button posts" do
      login_as(user)

      patch learner_notes_account_path, params: { enabled: "1" }
      expect(response).to redirect_to(account_path)
      follow_redirect!
      expect(response.body).to include("Learner notes are on.")
      expect(setting_section.text).to include("Learner notes: on")
      expect(user.reload.learner_notes_enabled).to be(true)

      2.times { patch learner_notes_account_path, params: { enabled: "0" } }
      follow_redirect!
      expect(response.body).to include("Learner notes are off.")
      expect(user.reload.learner_notes_enabled).to be(false)
    end

    it "writes the setting under the user row lock" do
      login_as(user)
      locked = []
      allow_any_instance_of(User).to receive(:with_lock).and_wrap_original do |original, *args, &block|
        locked << original.receiver.id
        original.call(*args, &block)
      end

      patch learner_notes_account_path, params: { enabled: "1" }

      expect(locked).to include(user.id)
      expect(user.reload.learner_notes_enabled).to be(true)
    end

    it "is not offered on a house key, and refuses to turn on there" do
      trial_user = create_trial_user
      login_as(trial_user)

      get account_path
      expect(setting_section).to be_nil

      patch learner_notes_account_path, params: { enabled: "1" }
      expect(response).to redirect_to(account_path)
      follow_redirect!
      expect(response.body).to include("Learner notes need your own API key.")
      expect(trial_user.reload.learner_notes_enabled).to be(false)
    end
  end

  context "with LEARNER_NOTES off" do
    it "hides the setting and refuses a posted change" do
      login_as(user)

      get account_path
      expect(setting_section).to be_nil

      patch learner_notes_account_path, params: { enabled: "1" }
      expect(response).to have_http_status(:not_found)
      expect(user.reload.learner_notes_enabled).to be(false)
    end
  end
end
