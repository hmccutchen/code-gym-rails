require "rails_helper"

RSpec.describe UserMailer, type: :mailer do
  describe "#login_code" do
    let(:user) { User.create!(email: "dev@example.com", name: "Dev") }
    let(:mail) { UserMailer.login_code(user, "123456") }

    it "addresses the email correctly" do
      expect(mail.to).to eq([ "dev@example.com" ])
      expect(mail.subject).to eq("Your Coding Gym login code")
    end

    it "contains the raw code" do
      expect(mail.body.encoded).to include("123456")
    end

    it "says where the code has to be entered" do
      expect(mail.body.encoded).to match(/browser where you requested it/i)
    end

    it "greets the user and states when the code expires" do
      body = mail.body.encoded

      expect(body).to include("Hi Dev,")
      expect(body).to include("It expires in #{User.login_code_expiry_in_words}.")
    end

    it "carries no login link" do
      expect(mail.body.encoded).not_to include("/auth/verify")
    end
  end

  describe "#second_factor_changed" do
    let(:user) { User.create!(email: "dev@example.com", name: "Dev", time_zone: "America/New_York") }
    let(:changed_at) { Time.utc(2026, 10, 23, 14, 5) }

    it "says what changed and when, in the user's zone" do
      mail = described_class.second_factor_changed(user, "enabled", changed_at)

      expect(mail.to).to eq([ "dev@example.com" ])
      expect(mail.subject).to eq("Your Coding Gym sign-in settings changed")
      expect(mail.body.encoded).to include("An authenticator app was turned on", "October 23, 2026 10:05")
      expect(mail.body.encoded).to include("If you didn't do this")
    end

    it "has a sentence for each change" do
      expect(described_class.second_factor_changed(user, "disabled", changed_at).body.encoded).to include("turned off")
      expect(described_class.second_factor_changed(user, "recovery_codes", changed_at).body.encoded)
        .to include("New recovery codes were made")
    end

    it "refuses a change it has no sentence for" do
      expect { described_class.second_factor_changed(user, "other", changed_at).body }.to raise_error(KeyError)
    end
  end
end
