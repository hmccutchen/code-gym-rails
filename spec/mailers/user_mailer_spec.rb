require "rails_helper"

RSpec.describe UserMailer, type: :mailer do
  describe "#magic_link" do
    let(:user) { User.create!(email: "dev@example.com", name: "Dev") }
    let(:raw_token) { user.generate_login_token! }
    let(:mail) { UserMailer.magic_link(user, raw_token) }

    it "addresses the email correctly" do
      expect(mail.to).to eq([ "dev@example.com" ])
      expect(mail.subject).to eq("Your Code Gym login link")
    end

    it "contains the verification link with the raw token" do
      expect(mail.body.encoded).to include("/auth/verify?token=#{raw_token}")
    end

    it "builds an absolute URL from the configured mailer host" do
      expect(mail.body.encoded).to match(%r{https?://example\.com/auth/verify})
    end

    it "includes the raw login code when one is provided" do
      mail_with_code = UserMailer.magic_link(user, raw_token, "123456")
      expect(mail_with_code.body.encoded).to include("123456")
    end

    it "omits any code line when no code is provided" do
      expect(mail.body.encoded).not_to include("enter this code")
    end
  end
end
