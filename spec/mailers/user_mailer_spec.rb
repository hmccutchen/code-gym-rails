require "rails_helper"

RSpec.describe UserMailer, type: :mailer do
  describe "#login_code" do
    let(:user) { User.create!(email: "dev@example.com", name: "Dev") }
    let(:mail) { UserMailer.login_code(user, "123456") }

    it "addresses the email correctly" do
      expect(mail.to).to eq([ "dev@example.com" ])
      expect(mail.subject).to eq("Your Code Gym login code")
    end

    it "contains the raw code" do
      expect(mail.body.encoded).to include("123456")
    end

    # The code only works in the browser that asked for it, so an email that
    # did not say so would send people to whichever device opened the mail.
    it "says where the code has to be entered" do
      expect(mail.body.encoded).to match(/browser where you requested it/i)
    end

    it "carries no login link" do
      expect(mail.body.encoded).not_to include("/auth/verify")
    end
  end
end
