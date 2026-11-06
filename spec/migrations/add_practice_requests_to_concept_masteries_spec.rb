require "rails_helper"
require Rails.root.join("db/migrate/20261106220648_add_practice_requests_to_concept_masteries").to_s

RSpec.describe AddPracticeRequestsToConceptMasteries do
  let(:connection) { ActiveRecord::Base.connection }
  let(:user) { User.create!(email: "practice-schema@example.com") }
  let(:mastery) do
    id = ConceptMastery.insert!({ user_id: user.id, concept: "n_plus_one", language: "ruby_rails",
      tier: :reduced, streak: 2, last_rating: "strong", mastered_at: Time.utc(2026, 11, 4, 9),
      retention_interval_days: 7, next_retention_check_on: Date.new(2026, 11, 11),
      drilled_at: Time.utc(2026, 11, 5, 8), drill_group: "rails_data", cooldown_remaining: 1 }).first.fetch("id")
    ConceptMastery.find(id)
  end

  after { ConceptMastery.reset_column_information }

  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { described_class.new.migrate(direction) }
    ConceptMastery.reset_column_information
  end

  it "reserves non-null JSONB storage with an empty object default" do
    column = connection.columns(:concept_masteries).find { |candidate| candidate.name == "practice_requests" }

    expect(column).to have_attributes(type: :jsonb, default: "{}", null: false)
  end

  it "leaves practice state uninitialized when an insert omits the field" do
    expect(mastery.practice_requests).to eq({})
  end

  it "rejects an explicit SQL null" do
    expect do
      ConceptMastery.transaction(requires_new: true) { mastery.update_column(:practice_requests, nil) }
    end.to raise_error(ActiveRecord::NotNullViolation)
  end

  it "preserves existing mastery data without deriving practice state from retention or drill fields" do
    before = mastery.attributes.except("practice_requests")

    begin
      migrate(:down)

      expect(connection.column_exists?(:concept_masteries, :practice_requests)).to be false
      expect(mastery.reload.attributes).to eq(before)
    ensure
      migrate(:up)
    end

    expect(mastery.reload.practice_requests).to eq({})
    expect(mastery.attributes.except("practice_requests")).to eq(before)
  end
end
