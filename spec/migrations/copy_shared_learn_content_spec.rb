require "rails_helper"
require Rails.root.join("db/migrate/20261113150000_copy_shared_learn_content").to_s

RSpec.describe CopySharedLearnContent do
  around { |example| with_shared_learn_rows { example.run } }

  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }
  let!(:last_ids) { %w[concept_references recognition_guides].index_with { |table| max_id(table) } }
  let!(:ana) { new_user("ana") }
  let!(:ben) { new_user("ben") }
  let(:reference_content) do
    connection.columns(:concept_references).map(&:name)
      .excluding("id", "user_id", "concept", "language", "created_at", "updated_at")
      .index_with { |name| name == "lesson" ? { "steps" => [ "one" ] }.to_json : "#{name} text" }
      .merge("generation_version" => 4)
  end
  let(:written_at) { Time.zone.parse("2026-10-01 09:00") }

  after do
    User.where(email: created_emails).find_each { |user| AccountDeletion.call(user) }
    last_ids.each { |table, id| connection.execute("DELETE FROM #{table} WHERE id > #{id}") }
  end

  def created_emails = @created_emails ||= []

  def new_user(name)
    User.create!(email: "#{name}-copy-#{SecureRandom.hex(6)}@example.com").tap { |user| created_emails << user.email }
  end

  def max_id(table) = connection.select_value("SELECT coalesce(max(id), 0) FROM #{table}")

  def migrate
    ActiveRecord::Migration.suppress_messages { described_class.new.migrate(:up) }
  end

  def insert(table, attributes)
    columns = attributes.keys.map { |name| connection.quote_column_name(name) }.join(", ")
    values = attributes.values.map { |value| connection.quote(value) }.join(", ")
    connection.select_value("INSERT INTO #{table} (#{columns}) VALUES (#{values}) RETURNING id")
  end

  def shared_reference(concept: "open_closed")
    insert(:concept_references, reference_content.merge("concept" => concept, "language" => "ruby_rails",
                                                        "created_at" => written_at, "updated_at" => written_at))
  end

  def shared_guide(group_key: "data_modeling")
    insert(:recognition_guides, "group_key" => group_key, "questions" => "q", "contrast" => "c", "misfires" => "m",
                                "created_at" => written_at, "updated_at" => written_at)
  end

  def content_of(table, **conditions)
    where = conditions.map { |column, value| "#{column} = #{connection.quote(value)}" }.join(" AND ")
    connection.select_one("SELECT * FROM #{table} WHERE #{where}").except("id", "user_id")
  end

  it "gives every active user their own copy of each shared reference and guide" do
    shared_reference
    shared_reference(concept: "single_responsibility")
    shared_guide

    migrate

    [ ana, ben ].each do |user|
      expect(ConceptReference.where(user_id: user.id).pluck(:concept)).to contain_exactly("open_closed", "single_responsibility")
      expect(RecognitionGuide.where(user_id: user.id).pluck(:group_key)).to eq([ "data_modeling" ])
    end
  end

  it "copies every column but id and user_id as it is, versions and timestamps included" do
    reference_id = shared_reference
    guide_id = shared_guide

    migrate

    expect(content_of(:concept_references, user_id: ana.id)).to eq(content_of(:concept_references, id: reference_id))
    expect(content_of(:recognition_guides, user_id: ana.id)).to eq(content_of(:recognition_guides, id: guide_id))
    expect(ConceptReference.find_by!(user_id: ana.id).generation_version).to eq(4)
  end

  it "copies nothing to an anonymized account" do
    shared_reference
    shared_guide
    ben.update_columns(anonymized_at: Time.current)

    migrate

    expect(ConceptReference.where(user_id: ben.id)).to be_empty
    expect(RecognitionGuide.where(user_id: ben.id)).to be_empty
  end

  it "copies nothing to an account anonymized after the list of active accounts was read" do
    shared_reference
    shared_guide
    ben.update_columns(anonymized_at: Time.current)

    connection.transaction { described_class.copy_to(connection, ben.id) }

    expect(ConceptReference.where(user_id: ben.id)).to be_empty
    expect(RecognitionGuide.where(user_id: ben.id)).to be_empty
  end

  it "copies to a trial account, which can read the shared text today" do
    shared_reference
    ben.update_columns(trial_started_at: 1.day.ago, trial_ends_at: 1.week.from_now)

    migrate

    expect(ConceptReference.where(user_id: ben.id).count).to eq(1)
  end

  it "leaves a row the user already owns untouched" do
    shared_reference
    shared_guide
    own = ConceptReference.create!(user: ana, concept: "open_closed", language: "ruby_rails", tagline: "mine",
                                   generation_version: 9)
    own_guide = RecognitionGuide.create!(user: ana, group_key: "data_modeling", questions: "my q", contrast: "my c",
                                         misfires: "my m")

    expect { migrate }.not_to(change { [ own.reload.attributes, own_guide.reload.attributes ] })

    expect(ConceptReference.where(user_id: ana.id).count).to eq(1)
    expect(RecognitionGuide.where(user_id: ana.id).count).to eq(1)
    expect(ConceptReference.find_by!(user_id: ben.id).tagline).to eq("tagline text")
  end

  it "adds nothing when it runs again, so L5 can repeat it for whoever is still missing a copy" do
    shared_reference
    shared_guide
    migrate

    expect { migrate }.not_to(change { [ ConceptReference.count, RecognitionGuide.count ] })

    carl = new_user("carl")
    described_class.copy_to_active_users(connection)

    expect(ConceptReference.where(user_id: carl.id).count).to eq(1)
    expect(RecognitionGuide.where(user_id: carl.id).count).to eq(1)
  end

  it "refuses to run inside a transaction, which would hold every user's lock until the end" do
    shared_reference

    connection.transaction do
      expect { described_class.copy_to_active_users(connection) }
        .to raise_error(ArgumentError, /disable_ddl_transaction!/)
    end
    expect(ConceptReference.where(user_id: [ ana.id, ben.id ])).to be_empty
  end

  it "keeps the shared rows" do
    reference_id = shared_reference
    guide_id = shared_guide

    migrate

    expect(ConceptReference.where(user_id: nil, id: (last_ids["concept_references"] + 1)..).ids).to eq([ reference_id ])
    expect(RecognitionGuide.where(user_id: nil, id: (last_ids["recognition_guides"] + 1)..).ids).to eq([ guide_id ])
  end

  it "leaves another user's own row out of the copy" do
    ConceptReference.create!(user: ben, concept: "open_closed", language: "ruby_rails", tagline: "ben's")

    migrate

    expect(ConceptReference.where(user_id: ana.id)).to be_empty
  end

  it "changes nothing on the way down" do
    shared_reference
    migrate

    expect { ActiveRecord::Migration.suppress_messages { described_class.new.migrate(:down) } }
      .not_to(change { ConceptReference.count })
  end

  it "keeps its helpers private, so only the two copy methods are L5's to call" do
    expect(described_class.public_methods(false)).to include(:copy_to, :copy_to_active_users)
    expect(described_class.public_methods(false)).not_to include(:owner_keys, :copy_sql)
  end
end
