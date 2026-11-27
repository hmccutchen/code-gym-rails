require "rails_helper"
require Rails.root.join("db/migrate/20261127120001_add_section_order_to_daily_exercises").to_s

RSpec.describe AddSectionOrderToDailyExercises do
  after { DailyExercise.reset_column_information }

  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { described_class.new.migrate(direction) }
  end

  it "reads and validates full rows while the model still has its pre-migration metadata" do
    user = User.create!(email: "manifest-migration@example.com")
    exercise = user.daily_exercises.create!(date: Date.current, generated_at: Time.current,
      problem_set: { "code_review" => {}, "pattern" => {} })
    migrate(:down)
    DailyExercise.reset_column_information
    expect(DailyExercise.column_names).not_to include("section_order")
    expect(DailyExercise.find(exercise.id).active_section_keys).to eq(%w[code_review pattern])

    migrate(:up)
    expect(DailyExercise.column_names).not_to include("section_order")

    row = DailyExercise.uncached { DailyExercise.find(exercise.id) }
    expect(row.has_attribute?(:section_order)).to be(true)
    expect(row.active_section_keys).to eq(%w[code_review pattern])
    expect(row).to be_valid

    DailyExercise.reset_column_information
    row.reload.update!(section_order: %w[pattern])
    expect(row.reload.active_section_keys).to eq(%w[pattern])
  end
end
