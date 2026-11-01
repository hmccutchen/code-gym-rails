require "rails_helper"

migration_path = Rails.root.join("db/migrate/20261101120000_drop_legacy_rating_from_daily_responses.rb")
require migration_path.to_s

RSpec.describe DropLegacyRatingFromDailyResponses do
  let(:connection) { ActiveRecord::Base.connection }
  let(:user) { User.create!(email: "kept@example.com", name: "Kept") }
  let(:exercise) { DailyExercise.create!(user: user, date: Date.current, problem_set: { "code_review" => {} }, generated_at: Time.current) }
  let!(:response) do
    DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current, answers: {}, section_ratings: { "code_review" => "too_hard" })
  end

  after { DailyResponse.reset_column_information }

  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { described_class.new.migrate(direction) }
    DailyResponse.reset_column_information
  end

  def legacy_rating_column
    connection.columns(:daily_responses).find { |column| column.name == "legacy_rating" }
  end

  it "rolls back by restoring an empty, nullable string column" do
    migrate(:down)

    expect(legacy_rating_column).to have_attributes(type: :string, null: true)
    expect(connection.select_value("SELECT legacy_rating FROM daily_responses WHERE id = #{response.id}")).to be_nil
  ensure
    migrate(:up)
  end

  it "drops the column and keeps the responses and their section ratings" do
    migrate(:down)
    connection.execute("UPDATE daily_responses SET legacy_rating = 'too_hard'")

    migrate(:up)

    expect(legacy_rating_column).to be_nil
    expect(response.reload.section_ratings).to eq("code_review" => "too_hard")
  end
end
