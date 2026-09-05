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

    # The caller wraps this in a transaction. A bare RecordNotUnique there
    # aborts it, so without the SAVEPOINT the retry's own query raises
    # PG::InFailedSqlTransaction rather than recovering.
    it "recovers inside a surrounding transaction when the insert loses a race" do
      raised = false
      allow(described_class).to receive(:find_or_initialize_by).and_wrap_original do |original, *args|
        described_class.unscoped.create!(user: user, endpoint: "https://push.example.com/abc", p256dh_key: "x", auth_key: "y") unless raised
        raised = true
        original.call(*args)
      end

      result = ActiveRecord::Base.transaction { described_class.register!(**attributes) }

      expect(result.p256dh_key).to eq("p256")
      expect(described_class.count).to eq(1)
      expect { described_class.count }.not_to raise_error
    end

    # Uniqueness is enforced twice and the validation fires first, so the loser
    # of the race sees RecordInvalid at least as often as RecordNotUnique.
    it "recovers when the uniqueness validation raises rather than the index" do
      described_class.register!(**attributes.merge(p256dh_key: "stale"))

      calls = 0
      allow(described_class).to receive(:find_or_initialize_by).and_wrap_original do |original, *args|
        calls += 1
        calls == 1 ? described_class.new(endpoint: "https://push.example.com/abc") : original.call(*args)
      end

      result = described_class.register!(**attributes)

      expect(result.p256dh_key).to eq("p256")
      expect(described_class.count).to eq(1)
    end

    it "re-raises an invalid record that has nothing to do with the endpoint" do
      expect { described_class.register!(**attributes.merge(p256dh_key: "")) }
        .to raise_error(ActiveRecord::RecordInvalid)
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
