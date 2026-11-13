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

  it "keeps different keys apart" do
    other_session.select_value(described_class.statement("pg_advisory_lock", "write-up/2"))

    expect(described_class.hold("write-up/1") { :ran }).to be(true)
  end
end
