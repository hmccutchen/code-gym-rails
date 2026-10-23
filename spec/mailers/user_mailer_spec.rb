require "rails_helper"

RSpec.describe UserMailer, type: :mailer do
  describe "#login_code" do
    let(:user) { User.create!(email: "dev@example.com", name: "Dev") }
    let(:mail) { UserMailer.login_code(user) }
    let(:raw_code) { mail.body.encoded[/is:\s*(\d{6})/m, 1] }

    it "addresses the email correctly" do
      expect(mail.to).to eq([ "dev@example.com" ])
      expect(mail.subject).to eq("Your Coding Gym login code")
    end

    it "mints the code it carries, and that code signs the account in" do
      expect(raw_code).to be_present
      expect(User.authenticate_login_code(email: user.email, code: raw_code)).to eq(user)
    end

    it "replaces any earlier code when the email is built, so only the newest email works" do
      user.generate_login_code!

      expect { mail.body }.to change { user.reload.login_code_digest }
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
end
