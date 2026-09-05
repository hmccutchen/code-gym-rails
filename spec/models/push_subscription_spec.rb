require "rails_helper"

RSpec.describe PushSubscription, type: :model do
  let(:user) { create_user_with_key }

  def attributes(endpoint: "https://push.example.com/abc")
    { user: user, endpoint: endpoint, p256dh_key: "p256", auth_key: "auth" }
  end

  describe ".register!" do
    it "creates a row for an endpoint it has not seen" do
      expect { described_class.register!(**attributes) }.to change(described_class, :count).by(1)
    end

    # The client re-subscribes on every launch, so the common case is an
    # endpoint that already has a row. A second row for the same browser would
    # mean the same device notified twice every morning.
    it "refreshes the existing row rather than adding a second one" do
      described_class.register!(**attributes)

      expect {
        described_class.register!(**attributes.merge(p256dh_key: "rotated"))
      }.not_to change(described_class, :count)

      expect(described_class.sole.p256dh_key).to eq("rotated")
    end

    it "reassigns an endpoint that now belongs to a different user" do
      described_class.register!(**attributes)
      other = create_user_with_key(email: "other@example.com")

      described_class.register!(**attributes.merge(user: other))

      expect(described_class.sole.user).to eq(other)
    end
  end

  it "is destroyed with its user" do
    described_class.register!(**attributes)

    expect { user.destroy }.to change(described_class, :count).by(-1)
  end
end
