require "rails_helper"
require Rails.root.join("db/migrate/20261113150000_copy_shared_learn_content").to_s

RSpec.describe CopySharedLearnContent do
  let(:connection) { ActiveRecord::Base.connection }
  let!(:ana) { User.create!(email: "ana-copy@example.com") }
  let!(:ben) { User.create!(email: "ben-copy@example.com") }
  let(:reference_content) do
    ConceptReference.column_names.excluding("id", "user_id", "concept", "language", "created_at", "updated_at")
      .index_with { |name| name == "lesson" ? { "steps" => [ "one" ] } : "#{name} text" }
      .merge("generation_version" => 4)
  end
  let(:written_at) { Time.zone.parse("2026-10-01 09:00") }

  def migrate
    ActiveRecord::Migration.suppress_messages { described_class.new.migrate(:up) }
  end

  def shared_reference(concept: "open_closed", **attributes)
    ConceptReference.create!(reference_content.merge(concept: concept, language: "ruby_rails",
                                                     created_at: written_at, updated_at: written_at, **attributes))
  end

  def shared_guide(group_key: "data_modeling")
    RecognitionGuide.create!(group_key: group_key, questions: "q", contrast: "c", misfires: "m",
                             created_at: written_at, updated_at: written_at)
  end

  def content_of(record) = record.attributes.except("id", "user_id")

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
    reference = shared_reference
    guide = shared_guide

    migrate

    expect(content_of(ConceptReference.find_by!(user_id: ana.id))).to eq(content_of(reference))
    expect(content_of(RecognitionGuide.find_by!(user_id: ana.id))).to eq(content_of(guide))
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

    carl = User.create!(email: "carl-copy@example.com")
    described_class.copy_to_active_users(connection)

    expect(ConceptReference.where(user_id: carl.id).count).to eq(1)
    expect(RecognitionGuide.where(user_id: carl.id).count).to eq(1)
  end

  it "keeps the shared rows" do
    reference = shared_reference
    guide = shared_guide

    migrate

    expect(ConceptReference.where(user_id: nil)).to eq([ reference ])
    expect(RecognitionGuide.where(user_id: nil)).to eq([ guide ])
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
end
