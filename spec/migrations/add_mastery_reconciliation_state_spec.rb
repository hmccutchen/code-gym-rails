require "rails_helper"
require Rails.root.join("db/migrate/20261106062129_add_mastery_reconciliation_state").to_s

RSpec.describe AddMasteryReconciliationState do
  let(:connection) { ActiveRecord::Base.connection }
  let(:user) { User.create!(email: "schema-preparation@example.com") }
  let(:exercise) do
    DailyExercise.create!(user: user, date: Date.new(2026, 11, 5),
      problem_set: { "code_review" => {} }, generated_at: Time.utc(2026, 11, 5, 8))
  end
  let(:response) do
    id = DailyResponse.insert!({ user_id: user.id, daily_exercise_id: exercise.id, date: exercise.date,
      answers: { "code_review" => "Add an index" }, section_ratings: { "code_review" => "got_it" },
      ai_review: { "code_review" => { "rating" => "solid" } },
      concept_tags: { "code_review" => "n_plus_one" }, submitted_at: Time.utc(2026, 11, 5, 9) }).first.fetch("id")
    DailyResponse.find(id)
  end
  let(:mastery) do
    id = ConceptMastery.insert!({ user_id: user.id, concept: "n_plus_one", language: "ruby_rails",
      tier: :reduced, streak: 2, last_rating: "solid", mastered_at: Time.utc(2026, 11, 4, 9),
      retention_interval_days: 7, next_retention_check_on: Date.new(2026, 11, 11),
      drilled_at: Time.utc(2026, 11, 5, 8), drill_group: "rails", cooldown_remaining: 1 }).first.fetch("id")
    ConceptMastery.find(id)
  end

  after { [ DailyResponse, ConceptMastery ].each(&:reset_column_information) }

  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { described_class.new.migrate(direction) }
    [ DailyResponse, ConceptMastery ].each(&:reset_column_information)
  end

  { response: :mastery_application, mastery: :review_reconciliation }.each do |record_name, field|
    context field.to_s do
      let(:record) { public_send(record_name) }

      it "reserves non-null JSONB storage with an empty object default" do
        column = connection.columns(record.class.table_name).find { |candidate| candidate.name == field.to_s }

        expect(column).to have_attributes(type: :jsonb, default: "{}", null: false)
      end

      it "defaults to an empty object when an insert omits the field" do
        expect(record[field]).to eq({})
      end

      it "rejects an explicit SQL null" do
        expect do
          record.class.transaction(requires_new: true) { record.update_column(field, nil) }
        end.to raise_error(ActiveRecord::NotNullViolation)
      end
    end
  end

  it "migrates down and up without changing other data and defaults existing rows to empty objects" do
    response_before = response.attributes.except("mastery_application")
    mastery_before = mastery.attributes.except("review_reconciliation")

    begin
      migrate(:down)

      expect(connection.column_exists?(:daily_responses, :mastery_application)).to be false
      expect(connection.column_exists?(:concept_masteries, :review_reconciliation)).to be false
      expect(response.reload.attributes).to eq(response_before)
      expect(mastery.reload.attributes).to eq(mastery_before)
    ensure
      migrate(:up)
    end

    expect(response.reload.mastery_application).to eq({})
    expect(mastery.reload.review_reconciliation).to eq({})
    expect(response.attributes.except("mastery_application")).to eq(response_before)
    expect(mastery.attributes.except("review_reconciliation")).to eq(mastery_before)
  end
end
