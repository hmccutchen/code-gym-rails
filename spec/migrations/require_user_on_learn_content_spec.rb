require "rails_helper"
require Rails.root.join("db/migrate/20261113190000_require_user_on_learn_content").to_s

RSpec.describe RequireUserOnLearnContent do
  around { |example| with_shared_learn_rows { example.run } }

  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }
  let!(:last_ids) { %w[concept_references recognition_guides].index_with { |table| max_id(table) } }

  after do
    User.where(email: created_emails).find_each { |user| AccountDeletion.call(user) }
    last_ids.each { |table, id| connection.execute("DELETE FROM #{table} WHERE id > #{id}") }
  end

  def created_emails = @created_emails ||= []

  def new_user(name)
    User.create!(email: "#{name}-owner-required-#{SecureRandom.hex(6)}@example.com").tap { |user| created_emails << user.email }
  end

  def max_id(table) = connection.select_value("SELECT coalesce(max(id), 0) FROM #{table}")

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

  def reference(user_id, tagline:, concept: "open_closed")
    connection.execute(<<~SQL)
      INSERT INTO concept_references (user_id, concept, language, tagline, generation_version, created_at, updated_at)
      VALUES (#{user_id || 'NULL'}, '#{concept}', 'ruby_rails', '#{tagline}', 2, now(), now())
    SQL
  end

  def guide(user_id, questions:)
    connection.execute(<<~SQL)
      INSERT INTO recognition_guides (user_id, group_key, questions, contrast, misfires, created_at, updated_at)
      VALUES (#{user_id || 'NULL'}, 'data_modeling', '#{questions}', 'c', 'm', now(), now())
    SQL
  end

  def new_rows(table)
    connection.select_rows("SELECT user_id, #{table == 'concept_references' ? 'tagline' : 'questions'} FROM #{table} " \
                           "WHERE id > #{last_ids[table]} ORDER BY user_id NULLS FIRST")
  end

  it "copies the shared rows to an account created after L5's copy, then deletes them" do
    late = new_user("late")
    writer = new_user("writer")
    reference(nil, tagline: "shared")
    guide(nil, questions: "shared")
    reference(writer.id, tagline: "mine")

    migrate(:up)

    expect(new_rows("concept_references")).to eq([ [ late.id, "shared" ], [ writer.id, "mine" ] ])
    expect(new_rows("recognition_guides")).to eq([ [ late.id, "shared" ], [ writer.id, "shared" ] ])
    expect(ConceptReference.find_by!(user: late).generation_version).to eq(2)
  end

  it "makes user_id NOT NULL on both tables, keeping the foreign key to users" do
    migrate(:up)

    %w[concept_references recognition_guides].each do |table|
      expect(column(table, "user_id")).to have_attributes(sql_type: "bigint", null: false)
      expect(connection.foreign_keys(table).map { |key| [ key.column, key.to_table ] }).to include([ "user_id", "users" ])
    end
    expect { reference(nil, tagline: "shared") }.to raise_error(ActiveRecord::NotNullViolation)
    expect { guide(nil, questions: "shared") }.to raise_error(ActiveRecord::NotNullViolation)
  end

  it "drops the partial indexes over shared rows and keeps the per-user unique indexes L4's copy names" do
    owner = new_user("owner")
    migrate(:up)

    expect(index(:concept_references, %w[concept language])).to be_nil
    expect(index(:recognition_guides, %w[group_key])).to be_nil
    expect(index(:concept_references, %w[user_id concept language])).to have_attributes(unique: true, where: nil)
    expect(index(:recognition_guides, %w[user_id group_key])).to have_attributes(unique: true, where: nil)
    reference(owner.id, tagline: "first")
    expect { reference(owner.id, tagline: "second") }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "puts back the nullable column and the partial indexes on the way down, but not the deleted rows" do
    reference(nil, tagline: "shared")
    migrate(:up)

    migrate(:down)

    expect(column(:concept_references, "user_id")).to have_attributes(null: true)
    expect(column(:recognition_guides, "user_id")).to have_attributes(null: true)
    expect(index(:concept_references, %w[concept language])).to have_attributes(unique: true, where: "(user_id IS NULL)")
    expect(index(:recognition_guides, %w[group_key])).to have_attributes(unique: true, where: "(user_id IS NULL)")
    expect(new_rows("concept_references")).to be_empty
  end

  it "runs outside a transaction, since the copy commits one user at a time" do
    expect(described_class.disable_ddl_transaction).to be(true)
  end
end
