require "rails_helper"

RSpec.describe SignedInSessions do
  let(:user) { User.create!(email: "dev@example.com", name: "Dev") }

  describe "#session_signed_in_valid?" do
    it "accepts any stamped session while sessions_valid_after is unset" do
      expect(user.session_signed_in_valid?(User.session_stamp(1.year.ago))).to be(true)
    end

    it "accepts a session signed in at or after sessions_valid_after" do
      cutoff = Time.current
      user.update!(sessions_valid_after: cutoff)

      expect(user.session_signed_in_valid?(User.session_stamp(cutoff))).to be(true)
      expect(user.session_signed_in_valid?(User.session_stamp(cutoff + 1.second))).to be(true)
    end

    it "rejects a session signed in before sessions_valid_after" do
      user.update!(sessions_valid_after: Time.current)

      expect(user.session_signed_in_valid?(User.session_stamp(1.second.ago))).to be(false)
    end

    it "rejects a missing or unreadable stamp" do
      expect(user.session_signed_in_valid?(nil)).to be(false)
      expect(user.session_signed_in_valid?("yesterday")).to be(false)
    end
  end

  describe ".signed_in_through" do
    it "finds the active user a valid session names" do
      expect(User.signed_in_through({ user_id: user.id, signed_in_at: User.session_stamp })).to eq(user)
    end

    it "returns nil for an anonymized user" do
      user.anonymize!

      expect(User.signed_in_through({ user_id: user.id, signed_in_at: User.session_stamp })).to be_nil
    end

    it "returns nil for a session signed in before sessions_valid_after" do
      stamp = User.session_stamp(1.minute.ago)
      user.update!(sessions_valid_after: Time.current)

      expect(User.signed_in_through({ user_id: user.id, signed_in_at: stamp })).to be_nil
    end
  end
end
