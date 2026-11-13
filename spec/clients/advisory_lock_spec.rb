require "rails_helper"

RSpec.describe AdvisoryLock do
  let(:other_session) { ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.new(ActiveRecord::Base.connection_pool.db_config.configuration_hash) }

  after { other_session.disconnect! }

  def taken_elsewhere?(key)
    return true unless other_session.select_value(described_class.statement("pg_try_advisory_lock", key))

    other_session.select_value(described_class.statement("pg_advisory_unlock", key))
    false
  end

  it "runs the block while it holds the key, and answers true" do
    seen = nil

    expect(described_class.hold("write-up/1") { seen = taken_elsewhere?("write-up/1") }).to be(true)
    expect(seen).to be(true)
  end

  it "answers false without running the block when another session holds the key" do
    other_session.select_value(described_class.statement("pg_advisory_lock", "write-up/1"))
    ran = false

    expect(described_class.hold("write-up/1") { ran = true }).to be(false)
    expect(ran).to be(false)
  end

  it "lets go of the key when the block raises" do
    expect { described_class.hold("write-up/1") { raise ArgumentError } }.to raise_error(ArgumentError)

    expect(taken_elsewhere?("write-up/1")).to be(false)
  end

  it "logs a failed unlock and lets the block's own error through, since a lost session drops the lock anyway" do
    allow(Rails.logger).to receive(:warn)
    connection = ActiveRecord::Base.connection
    allow(connection).to receive(:select_value).and_call_original
    allow(connection).to receive(:select_value).with(described_class.statement("pg_advisory_unlock", "write-up/1"))
      .and_raise(ActiveRecord::ConnectionFailed, "server closed the connection")

    expect { described_class.hold("write-up/1") { raise ArgumentError, "the block's error" } }
      .to raise_error(ArgumentError, "the block's error")
    expect(Rails.logger).to have_received(:warn).with(/write-up\/1.*server closed the connection/)
  ensure
    connection.raw_connection.exec("SELECT pg_advisory_unlock_all()")
  end

  it "keeps different keys apart" do
    other_session.select_value(described_class.statement("pg_advisory_lock", "write-up/2"))

    expect(described_class.hold("write-up/1") { :ran }).to be(true)
  end
end
