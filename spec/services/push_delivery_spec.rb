require "rails_helper"

RSpec.describe PushDelivery do
  let(:user) { User.create!(email: "push@example.com", name: "Push") }
  let(:subscription) do
    PushSubscription.register!(user: user, endpoint: "https://push.example.com/abc", p256dh_key: "p256", auth_key: "auth")
  end

  around do |example|
    ENV["VAPID_PUBLIC_KEY"] = "public"
    ENV["VAPID_PRIVATE_KEY"] = "private"
    example.run
  ensure
    ENV.delete("VAPID_PUBLIC_KEY")
    ENV.delete("VAPID_PRIVATE_KEY")
  end

  def deliver
    described_class.deliver(subscription, title: "Ready", body: "3 sections waiting.", path: "/")
  end

  it "sends a payload the service worker can read, signed with the VAPID pair" do
    expect(WebPush).to receive(:payload_send) do |args|
      expect(args[:endpoint]).to eq("https://push.example.com/abc")
      expect(args[:vapid]).to include(public_key: "public", private_key: "private")
      expect(JSON.parse(args[:message])).to eq(
        "title" => "Ready",
        "options" => { "body" => "3 sections waiting.", "data" => { "path" => "/" } }
      )
    end

    expect(deliver).to be(true)
    expect(subscription.reload.last_delivered_at).to be_present
  end

  # The pruning is what keeps the job honest over time: iOS drops subscriptions
  # on its own, and a dropped endpoint answers 404/410 forever afterwards.
  [ WebPush::ExpiredSubscription, WebPush::InvalidSubscription ].each do |error|
    it "deletes the endpoint when the push service reports it gone (#{error})" do
      allow(WebPush).to receive(:payload_send).and_raise(error.new(double(body: "gone"), "host"))

      expect(deliver).to be(false)
      expect(PushSubscription.exists?(subscription.id)).to be(false)
    end
  end

  it "keeps the endpoint when the failure is transient" do
    allow(WebPush).to receive(:payload_send).and_raise(WebPush::PushServiceError.new(double(body: "unavailable"), "host"))

    expect(deliver).to be(false)
    expect(PushSubscription.exists?(subscription.id)).to be(true)
  end

  it "does not contact a push service when no keypair is configured" do
    ENV.delete("VAPID_PUBLIC_KEY")
    expect(WebPush).not_to receive(:payload_send)

    expect(deliver).to be(false)
  end
end
