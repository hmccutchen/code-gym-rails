require "rails_helper"
require Rails.root.join("db/migrate/20261011130000_add_mid_level_rung").to_s

RSpec.describe AddMidLevelRung do
  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }

  def rerun_migration
    ActiveRecord::Migration.suppress_messages do
      migration.migrate(:down)
      yield
      migration.migrate(:up)
    end
  ensure
    [ User, ConceptReference ].each(&:reset_column_information)
  end

  it "maps every legacy value and preserves every current level" do
    mappings = { "beginner" => "junior", "developing" => "junior", "solid" => "senior", "strong" => "principal_engineer" }
    expected = mappings.merge(KindDifficulty::LEVELS.index_with(&:itself))
    users = expected.keys.map.with_index do |level, index|
      User.create!(email: "level#{index}@example.com", name: "Level", skill_level: "junior")
    end

    rerun_migration do
      users.zip(expected.keys).each { |user, level| user.update_column(:skill_level, level) }
    end

    expect(User.where(id: users.map(&:id)).order(:id).pluck(:skill_level)).to eq(expected.values)
    expect(User.new.skill_level).to eq("junior")
    expect(ConceptReference.columns_hash.fetch("ladder_mid_level").type).to eq(:text)
    expect(ConceptReference.new.ladder_mid_level).to be_nil
  end

  it "changes the database default before any legacy backfill runs" do
    defaults = []
    rerun_migration do
      allow(migration).to receive(:execute).and_wrap_original do |original, sql|
        defaults << connection.columns(:users).find { |column| column.name == "skill_level" }.default
        original.call(sql)
      end
    end

    expect(defaults).not_to be_empty
    expect(defaults).to all(eq("junior"))
  end

  it "rolls back mid-level skills without downgrading other current levels" do
    users = KindDifficulty::LEVELS.map.with_index do |level, index|
      User.create!(email: "rollback#{index}@example.com", name: "Level", skill_level: level)
    end

    rerun_migration do
      expect(users.map { |user| user.reload.skill_level }).to eq(%w[junior junior senior principal_engineer])
      expect(connection.columns(:users).find { |column| column.name == "skill_level" }.default).to eq("developing")
      expect(connection.column_exists?(:concept_references, :ladder_mid_level)).to be false
    end
  end
end
