require "rails_helper"
require Rails.root.join("db/migrate/20261112140000_repeat_unopened_set_pause_fills").to_s

RSpec.describe RepeatUnopenedSetPauseFills do
  let(:connection) { ActiveRecord::Base.connection }
  let(:paused_at) { Time.utc(2026, 11, 12, 15) }

  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { described_class.new.migrate(direction) }
  end

  def stored(table, name, record)
    connection.select_value("SELECT #{name} FROM #{table} WHERE id = #{record.id}")
  end

  def exercise_for(user, date, created_at, opened_at: nil)
    DailyExercise.create!(user: user, date: date, problem_set: { "code_review" => {} },
      generated_at: created_at, created_at: created_at, opened_at: opened_at)
  end

  def user_with(email, **columns)
    User.create!(email: email).tap { |user| user.update_columns(columns) if columns.any? }
  end

  it "marks an account paused since the columns shipped as manual, and keeps its pause time" do
    paused = user_with("paused-since@example.com", paused_generation_at: paused_at)

    migrate(:up)

    expect(stored(:users, :generation_pause_source, paused)).to eq("manual")
    expect(stored(:users, :paused_generation_at, paused)).to eq(paused_at)
  end

  it "clears the source of an account resumed since the columns shipped" do
    resumed = user_with("resumed-since@example.com", generation_pause_source: "manual")

    migrate(:up)

    expect(stored(:users, :generation_pause_source, resumed)).to be_nil
    expect(stored(:users, :paused_generation_at, resumed)).to be_nil
  end

  it "keeps a source already recorded for a paused account and leaves a running account without one" do
    automatic = user_with("automatic@example.com", paused_generation_at: paused_at, generation_pause_source: "automatic")
    running = user_with("running@example.com")

    migrate(:up)

    expect(stored(:users, :generation_pause_source, automatic)).to eq("automatic")
    expect(stored(:users, :generation_pause_source, running)).to be_nil
  end

  it "marks a set created since the columns shipped as opened when it was created, and keeps a recorded time" do
    user = user_with("sets@example.com")
    created = Time.utc(2026, 11, 12, 13, 0, 5)
    unstamped = exercise_for(user, Date.new(2026, 11, 12), created)
    recorded = Time.utc(2026, 11, 11, 16)
    stamped = exercise_for(user, Date.new(2026, 11, 11), Time.utc(2026, 11, 11, 13), opened_at: recorded)

    migrate(:up)

    expect(stored(:daily_exercises, :opened_at, unstamped)).to eq(created)
    expect(stored(:daily_exercises, :opened_at, stamped)).to eq(recorded)
  end

  it "writes users before daily_exercises, the order the app takes its locks" do
    tables = []
    migration = described_class.new
    allow(migration).to receive(:execute) { |sql| tables << sql[/UPDATE (\w+)/, 1] }

    ActiveRecord::Migration.suppress_messages { migration.up }

    expect(tables).to eq(%w[users users daily_exercises])
  end

  it "rolls back by changing nothing, since code from before the fills reads none of these columns" do
    paused = user_with("kept@example.com", paused_generation_at: paused_at)
    exercise = exercise_for(paused, Date.new(2026, 11, 12), Time.utc(2026, 11, 12, 13))
    migrate(:up)

    migrate(:down)

    expect(stored(:users, :generation_pause_source, paused)).to eq("manual")
    expect(stored(:daily_exercises, :opened_at, exercise)).to eq(exercise.created_at)
  end
end
