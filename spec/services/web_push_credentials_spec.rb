require "rails_helper"

RSpec.describe WebPushCredentials do
  around do |example|
    original = ENV.slice("VAPID_PUBLIC_KEY", "VAPID_PRIVATE_KEY", "VAPID_SUBJECT", "MAIL_FROM")
    example.run
  ensure
    %w[VAPID_PUBLIC_KEY VAPID_PRIVATE_KEY VAPID_SUBJECT MAIL_FROM].each { |k| ENV.delete(k) }
    original.each { |k, v| ENV[k] = v }
  end

  describe ".configured?" do
    it "is true only when both halves of the keypair are present" do
      ENV["VAPID_PUBLIC_KEY"] = "public"
      ENV["VAPID_PRIVATE_KEY"] = "private"

      expect(described_class).to be_configured
    end

    it "is false when either half is missing" do
      ENV["VAPID_PUBLIC_KEY"] = "public"
      ENV.delete("VAPID_PRIVATE_KEY")

      expect(described_class).not_to be_configured
    end

    # A Railway variable set to an empty string is the likeliest way to half-
    # configure this, and it must read as "not configured" rather than as a key.
    it "treats a blank value as absent" do
      ENV["VAPID_PUBLIC_KEY"] = "  "
      ENV["VAPID_PRIVATE_KEY"] = "private"

      expect(described_class).not_to be_configured
    end
  end

  describe ".subject" do
    it "prefers an explicit VAPID_SUBJECT" do
      ENV["VAPID_SUBJECT"] = "mailto:ops@example.com"

      expect(described_class.subject).to eq("mailto:ops@example.com")
    end

    it "falls back to the address the app already sends mail from" do
      ENV.delete("VAPID_SUBJECT")
      ENV["MAIL_FROM"] = "gym@example.com"

      expect(described_class.subject).to eq("mailto:gym@example.com")
    end
  end
end
