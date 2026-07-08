require "rails_helper"

RSpec.describe User, type: :model do
  def create_user(email: "dev@example.com", name: "Dev")
    User.create!(email: email, name: name)
  end

  describe "validations" do
    it "requires a valid email" do
      user = User.new(email: "not-an-email", name: "Dev")
      expect(user).not_to be_valid
      expect(user.errors[:email]).to be_present
    end

    it "rejects duplicate emails case-insensitively" do
      create_user(email: "dev@example.com")
      dupe = User.new(email: "DEV@example.com", name: "Other")
      expect(dupe).not_to be_valid
    end

    it "downcases email before saving" do
      user = User.create!(email: "MiXeD@Example.COM", name: "Dev")
      expect(user.reload.email).to eq("mixed@example.com")
    end
  end

  describe "magic link tokens" do
    it "generates a token that can be looked up" do
      user = create_user
      raw_token = user.generate_login_token!

      expect(raw_token).to be_present
      expect(User.find_by_login_token(raw_token)).to eq(user)
    end

    it "returns nil for a token that was never issued" do
      create_user.generate_login_token!
      expect(User.find_by_login_token("wrong-token")).to be_nil
    end

    it "returns nil once the token has expired" do
      user = create_user
      raw_token = user.generate_login_token!

      travel(User::TOKEN_EXPIRY + 1.minute) do
        expect(User.find_by_login_token(raw_token)).to be_nil
      end
    end

    it "returns nil after the token is cleared" do
      user = create_user
      raw_token = user.generate_login_token!
      user.clear_login_token!

      expect(User.find_by_login_token(raw_token)).to be_nil
    end

    it "stores only a digest, never the raw token" do
      user = create_user
      raw_token = user.generate_login_token!

      expect(user.reload.login_token_digest).not_to include(raw_token)
    end
  end
end
