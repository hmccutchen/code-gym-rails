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

  it "runs the block inside Active Record's executor, with the query cache on, which a plain thread is not" do
    expect(Thread.new { ActiveSupport::Executor.active? }.value).to be_falsey
    expect(described_class.start { ActiveSupport::Executor.active? }.value).to be_truthy
    expect(described_class.start { ActiveRecord::Base.connection_pool.query_cache_enabled }.value).to be(true)
  end

  it "stays outside the application executor, whose development reload lock a joining parent would deadlock on" do
    expect(described_class.start { Rails.application.executor.active? }.value).to be_falsey
  end

  context "without a transactional test, so the thread checks out a connection of its own" do
    self.use_transactional_tests = false

    let(:pool) { ActiveRecord::Base.connection_pool }

    def checked_out = pool.connections.count(&:in_use?)

    it "returns a connection the work leased once the thread finishes" do
      before = checked_out

      expect(Thread.new { ActiveRecord::Base.lease_connection }.join).to be_a(Thread)
      expect(checked_out).to eq(before + 1)

      pool.reap
      before = checked_out
      described_class.start { ActiveRecord::Base.lease_connection }.join
      expect(checked_out).to eq(before)
    end
  end
end
