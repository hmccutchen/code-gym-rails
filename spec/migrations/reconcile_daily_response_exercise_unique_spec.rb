require "rails_helper"

RSpec.describe "Reconciling the response index after the track migration version collision" do
  let(:connection) { ActiveRecord::Base.connection }
  let(:migration_context) { connection.pool.migration_context }
  let(:user) { User.create!(email: "reconcile@example.com", name: "Reconcile") }
  let(:exercise) do
    DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current,
                          problem_set: { "code_review" => { "question" => "q" } })
  end

  around { |example| ActiveRecord::Migration.suppress_messages { example.run } }

  before do
    connection.pool.schema_migration.delete_version("20261011071900")
    expect(migration_context.get_all_versions).to include(20261011040000, 20261011050000)
  end

  def response(date, **attributes)
    DailyResponse.new(user: user, daily_exercise: exercise, date: date, answers: {}, **attributes)
                 .tap { |row| row.save!(validate: false) }
  end

  def response_index
    connection.indexes(:daily_responses).find { |index| index.columns == [ "daily_exercise_id" ] }
  end

  def index_oid
    connection.select_value("SELECT 'index_daily_responses_on_daily_exercise_id'::regclass::oid")
  end

  it "repairs an index skipped because the preview already recorded the old version" do
    connection.remove_index :daily_responses, :daily_exercise_id
    connection.add_index :daily_responses, :daily_exercise_id
    reviewed = response(Date.current - 3, submitted_at: 3.days.ago, ai_review: { "code_review" => { "rating" => "solid" } })
    extra = response(Date.current - 1, submitted_at: 1.day.ago)
    response(Date.current)
    [ reviewed, extra ].each do |row|
      connection.execute(<<~SQL)
        INSERT INTO review_follow_ups (daily_response_id, section, role, content, created_at, updated_at)
        VALUES (#{row.id}, 'code_review', 0, 'q', now(), now())
      SQL
    end

    migration_context.up(20261011071900)

    expect(response_index.unique).to be true
    expect(DailyResponse.where(daily_exercise_id: exercise.id)).to eq([ reviewed ])
    expect(ReviewFollowUp.where(daily_response_id: reviewed.id).count).to eq(1)
    expect(ReviewFollowUp.where(daily_response_id: extra.id)).to be_empty
    expect(migration_context.get_all_versions).to include(20261011071900)
  end

  it "leaves an already-correct index and its response untouched" do
    only = response(Date.current)
    original_oid = index_oid

    migration_context.up(20261011071900)

    expect(response_index.unique).to be true
    expect(index_oid).to eq(original_oid)
    expect(DailyResponse.find(only.id).attributes).to eq(only.attributes)
    expect(migration_context.get_all_versions).to include(20261011071900)

    migration_context.run(:down, 20261011071900)

    expect(response_index.unique).to be true
    expect(index_oid).to eq(original_oid)
    expect(migration_context.get_all_versions).not_to include(20261011071900)
  end
end
