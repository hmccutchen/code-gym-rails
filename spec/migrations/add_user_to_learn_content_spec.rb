require "rails_helper"
require Rails.root.join("db/migrate/20261113120000_add_user_to_learn_content").to_s

RSpec.describe AddUserToLearnContent do
  let(:connection) { ActiveRecord::Base.connection }
  let(:ana) { User.create!(email: "ana-learn@example.com") }
  let(:ben) { User.create!(email: "ben-learn@example.com") }

  after { [ ConceptReference, RecognitionGuide ].each(&:reset_column_information) }

  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { described_class.new.migrate(direction) }
    [ ConceptReference, RecognitionGuide ].each(&:reset_column_information)
  end

  def column(table, name)
    connection.columns(table).find { |candidate| candidate.name == name }
  end

  def index(table, columns)
    connection.indexes(table).find { |candidate| candidate.columns == columns }
  end

  def reference(user_id, concept: "open_closed", language: "ruby_rails")
    connection.execute(<<~SQL)
      INSERT INTO concept_references (user_id, concept, language, created_at, updated_at)
      VALUES (#{user_id || 'NULL'}, '#{concept}', '#{language}', now(), now())
    SQL
  end

  def guide(user_id, group_key: "data_modeling")
    connection.execute(<<~SQL)
      INSERT INTO recognition_guides (user_id, group_key, questions, contrast, misfires, created_at, updated_at)
      VALUES (#{user_id || 'NULL'}, '#{group_key}', 'q', 'c', 'm', now(), now())
    SQL
  end

  def savepoint(&) = ActiveRecord::Base.transaction(requires_new: true, &)

  it "adds a nullable user_id with a foreign key to users on both tables" do
    %w[concept_references recognition_guides].each do |table|
      expect(column(table, "user_id")).to have_attributes(sql_type: "bigint", null: true, default: nil)
      expect(connection.foreign_keys(table).map { |key| [ key.column, key.to_table ] }).to include([ "user_id", "users" ])
    end
  end

  it "indexes each person's rows uniquely with user_id first" do
    expect(index(:concept_references, %w[user_id concept language])).to have_attributes(unique: true, where: nil)
    expect(index(:recognition_guides, %w[user_id group_key])).to have_attributes(unique: true, where: nil)
  end

  it "keeps shared rows unique through partial indexes on rows with no user" do
    expect(index(:concept_references, %w[concept language])).to have_attributes(unique: true, where: "(user_id IS NULL)")
    expect(index(:recognition_guides, %w[group_key])).to have_attributes(unique: true, where: "(user_id IS NULL)")
  end

  it "refuses a second shared row for the same concept or group" do
    reference(nil)
    guide(nil)

    expect { savepoint { reference(nil) } }.to raise_error(ActiveRecord::RecordNotUnique)
    expect { savepoint { guide(nil) } }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "lets each person own a row beside the shared one, once each" do
    [ nil, ana.id, ben.id ].each do |user_id|
      reference(user_id)
      guide(user_id)
    end

    expect(connection.select_value("SELECT count(*) FROM concept_references")).to eq(3)
    expect(connection.select_value("SELECT count(*) FROM recognition_guides")).to eq(3)
    expect { savepoint { reference(ana.id) } }.to raise_error(ActiveRecord::RecordNotUnique)
    expect { savepoint { guide(ana.id) } }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "puts the tables back as they were on the way down" do
    migrate(:down)

    expect(column(:concept_references, "user_id")).to be_nil
    expect(column(:recognition_guides, "user_id")).to be_nil
    expect(index(:concept_references, %w[concept language])).to have_attributes(unique: true, where: nil)
    expect(index(:recognition_guides, %w[group_key])).to have_attributes(unique: true, where: nil)

    migrate(:up)

    expect(index(:concept_references, %w[concept language])).to have_attributes(where: "(user_id IS NULL)")
  end
end
