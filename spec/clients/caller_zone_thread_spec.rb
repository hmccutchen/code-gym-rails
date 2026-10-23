require "rails_helper"

RSpec.describe CallerZoneThread do
  it "runs the block in the caller's zone, which a plain thread does not inherit" do
    Time.use_zone("Asia/Tokyo") do
      expect(Thread.new { Time.zone.name }.value).not_to eq("Asia/Tokyo")
      expect(described_class.start { Time.zone.name }.value).to eq("Asia/Tokyo")
    end
  end

  it "returns the thread, so the caller can join it or read its value" do
    expect(described_class.start { :done }).to be_a(Thread)
  end
end
