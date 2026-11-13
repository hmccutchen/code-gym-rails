require "rails_helper"
require Rails.root.join("db/migrate/20261113170000_catch_up_shared_learn_content_copy").to_s

RSpec.describe CatchUpSharedLearnContentCopy do
  around { |example| with_shared_learn_rows { example.run } }

  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }
  let!(:last_ids) { %w[concept_references recognition_guides].index_with { |table| max_id(table) } }
  let!(:copied) { new_user("copied") }

  before do
    connection.execute(<<~SQL)
      INSERT INTO concept_references (concept, language, tagline, generation_version, created_at, updated_at)
      VALUES ('open_closed', 'ruby_rails', 'shared tagline', 2, now(), now())
    SQL
    connection.execute(<<~SQL)
      INSERT INTO recognition_guides (group_key, questions, contrast, misfires, created_at, updated_at)
      VALUES ('data_modeling', 'q', 'c', 'm', now(), now())
    SQL
    CopySharedLearnContent.copy_to_active_users(connection)
  end

  after do
    User.where(email: created_emails).find_each { |user| AccountDeletion.call(user) }
    last_ids.each { |table, id| connection.execute("DELETE FROM #{table} WHERE id > #{id}") }
  end

  def created_emails = @created_emails ||= []

  def new_user(name)
    User.create!(email: "#{name}-catch-up-#{SecureRandom.hex(6)}@example.com").tap { |user| created_emails << user.email }
  end

  def max_id(table) = connection.select_value("SELECT coalesce(max(id), 0) FROM #{table}")

  def migrate(direction = :up)
    ActiveRecord::Migration.suppress_messages { described_class.new.migrate(direction) }
  end

  def owned_counts(user)
    [ ConceptReference.where(user_id: user.id).count, RecognitionGuide.where(user_id: user.id).count ]
  end

  it "copies the shared rows to an account created after L4's copy ran" do
    late = new_user("late")

    migrate

    expect(owned_counts(late)).to eq([ 1, 1 ])
    expect(ConceptReference.find_by!(user_id: late.id)).to have_attributes(tagline: "shared tagline", generation_version: 2)
  end

  it "adds nothing for an account L4 already copied to, and leaves a row the user wrote as it is" do
    writer = new_user("writer")
    own = ConceptReference.create!(user: writer, concept: "open_closed", language: "ruby_rails", tagline: "mine")

    expect { migrate }.not_to(change { owned_counts(copied) })
    expect(own.reload.tagline).to eq("mine")
    expect(owned_counts(writer)).to eq([ 1, 1 ])
  end

  it "copies nothing to an anonymized account" do
    gone = new_user("gone")
    gone.update_columns(anonymized_at: Time.current)

    migrate

    expect(owned_counts(gone)).to eq([ 0, 0 ])
  end

  it "keeps the shared rows, which a later migration removes" do
    migrate

    expect(ConceptReference.where(user_id: nil, id: (last_ids["concept_references"] + 1)..).count).to eq(1)
    expect(RecognitionGuide.where(user_id: nil, id: (last_ids["recognition_guides"] + 1)..).count).to eq(1)
  end

  it "runs outside a transaction, so each user's copy commits on its own" do
    expect(described_class.disable_ddl_transaction).to be(true)
  end

  it "changes nothing on the way down" do
    late = new_user("late")
    migrate

    expect { migrate(:down) }.not_to(change { owned_counts(late) })
  end
end
