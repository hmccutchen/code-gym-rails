require "rails_helper"

RSpec.describe SchemaWait do
  before { allow(described_class).to receive(:sleep) }

  it "returns as soon as the table is present" do
    allow(described_class).to receive(:ready?).and_return(true)

    expect(described_class.call).to be(true)
    expect(described_class).not_to have_received(:sleep)
  end

  it "polls until the migrating service creates the table" do
    allow(described_class).to receive(:ready?).and_return(false, false, true)

    expect(described_class.call(interval: 0.01)).to be(true)
    expect(described_class).to have_received(:sleep).twice
  end

  # A failed pre-deploy stops the deploy, which beats a worker crash-looping on a missing schema.
  it "raises once the deadline passes" do
    allow(described_class).to receive(:ready?).and_return(false)

    expect { described_class.call(timeout: 0, interval: 0.01) }
      .to raise_error(SchemaWait::Timeout, /#{described_class::REQUIRED_TABLE}/)
  end

  describe ".ready?" do
    it "is true when the table the worker boots against exists" do
      expect(described_class).to be_ready
    end

    it "is false when it does not" do
      stub_const("#{described_class}::REQUIRED_TABLE", "a_table_that_does_not_exist")

      expect(described_class).not_to be_ready
    end

    # A cold preview environment may not have a reachable database yet.
    it "treats an unreachable database as not-yet-ready rather than an error" do
      allow(ActiveRecord::Base).to receive(:connection).and_raise(ActiveRecord::ConnectionNotEstablished)

      expect(described_class).not_to be_ready
    end
  end

  describe ".migrations_pending?" do
    it "is false when every migration file has run" do
      expect(described_class.migrations_pending?).to be(false)
    end

    it "is true while the newest migration file has not run yet" do
      newest = ActiveRecord::Base.connection_pool.migration_context.get_all_versions.max
      ActiveRecord::Base.connection.execute("DELETE FROM schema_migrations WHERE version = '#{newest}'")

      expect(described_class.migrations_pending?).to be(true)
    end

    it "agrees with Rails' own answer" do
      expect(described_class.migrations_pending?).to eq(ActiveRecord::Base.connection_pool.migration_context.needs_migration?)
    end

    it "answers whatever the clock says, where Rails' own check refuses a migration dated after it" do
      travel_to(Time.utc(2026, 1, 1)) { expect(described_class.migrations_pending?).to be(false) }
    end
  end

  # railway.worker.toml depends on this task name; a missed rename would surface only as a failed deploy.
  it "is reachable through the rake task the worker's pre-deploy step calls" do
    expect(File.read(Rails.root.join("railway.worker.toml")))
      .to include("bundle exec rails db:wait_for_schema")
    expect(File.read(Rails.root.join("lib/tasks/schema_wait.rake")))
      .to include("task wait_for_schema:")
  end
end
