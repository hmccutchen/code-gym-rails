require "rails_helper"

migration_path = Rails.root.join("db/migrate/20261011040000_make_daily_response_exercise_unique.rb")
require migration_path.to_s

RSpec.describe MakeDailyResponseExerciseUnique do
  let(:connection) { ActiveRecord::Base.connection }
  let(:user) { User.create!(email: "dup-#{SecureRandom.hex(3)}@example.com", name: "Dup") }
  let(:exercise) do
    DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current,
                          problem_set: { "code_review" => { "question" => "q" } })
  end

  around { |example| ActiveRecord::Migration.suppress_messages { example.run } }

  # Postgres DDL is transactional, so the example's rollback restores the unique index.
  before do
    connection.remove_index :daily_responses, :daily_exercise_id
    connection.add_index :daily_responses, :daily_exercise_id
  end

  def response(date, **attributes)
    DailyResponse.new(user: user, daily_exercise: exercise, date: date, answers: {}, **attributes)
                 .tap { |row| row.save!(validate: false) }
  end

  def unique_index?
    connection.indexes(:daily_responses).find { |index| index.columns == [ "daily_exercise_id" ] }.unique
  end

  it "keeps the response dated with the exercise and deletes an older draft" do
    older = response(Date.current - 3)
    current = response(Date.current)

    described_class.new.up

    expect(DailyResponse.where(daily_exercise_id: exercise.id)).to eq([ current ])
    expect(DailyResponse.exists?(older.id)).to be false
    expect(unique_index?).to be true
  end

  it "keeps the newest draft when none is dated with the exercise" do
    response(Date.current - 3)
    newest = response(Date.current - 1)

    described_class.new.up

    expect(DailyResponse.where(daily_exercise_id: exercise.id)).to eq([ newest ])
  end

  it "deletes a submitted extra and its follow-ups too" do
    extra = response(Date.current - 3, submitted_at: 3.days.ago)
    connection.execute(<<~SQL)
      INSERT INTO review_follow_ups (daily_response_id, section, role, content, created_at, updated_at)
      VALUES (#{extra.id}, 'code_review', 0, 'q', now(), now())
    SQL
    current = response(Date.current)

    described_class.new.up

    expect(DailyResponse.where(daily_exercise_id: exercise.id)).to eq([ current ])
    expect(ReviewFollowUp.where(daily_response_id: extra.id)).to be_empty
    expect(unique_index?).to be true
  end

  it "leaves an exercise with one response alone" do
    only = response(Date.current - 3)

    described_class.new.up

    expect(DailyResponse.where(daily_exercise_id: exercise.id)).to eq([ only ])
  end
end
