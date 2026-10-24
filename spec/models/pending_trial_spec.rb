require "rails_helper"

RSpec.describe PendingTrial do
  include AuthHelpers

  let(:consented_at) { Time.utc(2026, 10, 7, 14) }
  let(:invite) { mint_trial_code(seats: 1, days: 7, cap: 12).first }

  it "takes no session, which the controller layer owns" do
    expect(described_class).not_to respond_to(:remember, :forget, :take)
  end

  describe ".dump" do
    it "keeps the string-keyed shape sessions already hold" do
      stored = described_class.dump(email: "new@example.com", invite: invite, provider: "fake", consented_at: consented_at)

      expect(stored).to eq("email" => "new@example.com", "invite_code_id" => invite.id,
                            "provider" => "fake", "consented_at" => "2026-10-07T14:00:00Z")
    end
  end

  describe ".load" do
    it "reads back what .dump stored" do
      stored = described_class.dump(email: "new@example.com", invite: invite, provider: "fake", consented_at: consented_at)

      expect(described_class.load(stored)).to be_a(described_class)
    end

    it "returns nil for anything but a hash" do
      expect(described_class.load(nil)).to be_nil
      expect(described_class.load("pending")).to be_nil
    end
  end

  describe "#start_for" do
    before { stub_env("HOUSE_FAKE_API_KEY" => "fake-house-key") }

    def pending
      described_class.load(described_class.dump(email: "new@example.com", invite: invite, provider: "fake",
                                                consented_at: consented_at))
    end

    it "starts the trial for the address the form named" do
      user = User.create!(email: "new@example.com", name: "New")

      expect(pending.start_for(user)).to eq(:started)
      expect(user.reload).to be_trial_active
    end

    it "rejects another address" do
      user = User.create!(email: "other@example.com", name: "Other")

      expect(pending.start_for(user)).to eq(:rejected)
    end

    it "rejects a stored consent time it can't read" do
      user = User.create!(email: "new@example.com", name: "New")
      unreadable = described_class.load("email" => "new@example.com", "invite_code_id" => invite.id,
                                        "provider" => "fake", "consented_at" => "garbled")

      expect(unreadable.start_for(user)).to eq(:rejected)
    end

    it "leaves an account with its own key alone" do
      user = create_user_with_key(email: "new@example.com")

      expect(pending.start_for(user)).to eq(:has_own_key)
    end
  end
end
