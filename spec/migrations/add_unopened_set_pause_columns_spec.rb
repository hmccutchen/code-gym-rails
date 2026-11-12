require "rails_helper"
require Rails.root.join("db/migrate/20261112120000_add_unopened_set_pause_columns").to_s

RSpec.describe AddUnopenedSetPauseColumns do
  let(:connection) { ActiveRecord::Base.connection }
  let(:paused_at) { Time.utc(2026, 11, 3, 14) }

  after { [ User, DailyExercise ].each(&:reset_column_information) }

  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { described_class.new.migrate(direction) }
    [ User, DailyExercise ].each(&:reset_column_information)
  end

  def column(table, name)
    connection.columns(table).find { |candidate| candidate.name == name }
  end

  def stored(table, name, record)
    connection.select_value("SELECT #{name} FROM #{table} WHERE id = #{record.id}")
  end

  def exercise_for(user, date, created_at)
    DailyExercise.create!(user: user, date: date, problem_set: { "code_review" => {} },
      generated_at: created_at, created_at: created_at)
  end

  it "adds a nullable opened_at datetime to daily_exercises" do
    expect(column(:daily_exercises, "opened_at")).to have_attributes(type: :datetime, null: true, default: nil)
  end

  it "adds a nullable generation_pause_source string with no default to users" do
    expect(column(:users, "generation_pause_source")).to have_attributes(type: :string, null: true, default: nil)
  end

  it "adds a non-null generation_account_failures integer defaulting to 0 to users" do
    expect(column(:users, "generation_account_failures")).to have_attributes(type: :integer, null: false, default: "0")
    expect(User.create!(email: "new-account@example.com").generation_account_failures).to eq(0)
  end

  it "leaves a set created after the migration unopened" do
    exercise = exercise_for(User.create!(email: "after@example.com"), Date.new(2026, 11, 12), Time.utc(2026, 11, 12, 13))

    expect(stored(:daily_exercises, :opened_at, exercise)).to be_nil
  end

  context "with rows that predate the columns" do
    let(:user) { User.create!(email: "running@example.com") }
    let(:paused_user) { User.create!(email: "paused@example.com", paused_generation_at: paused_at) }
    let(:older) { exercise_for(user, Date.new(2026, 11, 4), Time.utc(2026, 11, 4, 13, 0, 5)) }
    let(:newer) { exercise_for(paused_user, Date.new(2026, 11, 5), Time.utc(2026, 11, 5, 13, 7, 41)) }

    before do
      migrate(:down)
      [ older, newer ]
      migrate(:up)
    end

    it "marks every existing set as opened when it was created" do
      expect(stored(:daily_exercises, :opened_at, older)).to eq(older.created_at)
      expect(stored(:daily_exercises, :opened_at, newer)).to eq(newer.created_at)
    end

    it "records an existing pause as manual and leaves an unpaused account with no source" do
      expect(stored(:users, :generation_pause_source, paused_user)).to eq("manual")
      expect(stored(:users, :generation_pause_source, user)).to be_nil
      expect(stored(:users, :paused_generation_at, paused_user)).to eq(paused_at)
    end

    it "starts every existing account with no key failures" do
      expect(stored(:users, :generation_account_failures, user)).to eq(0)
      expect(stored(:users, :generation_account_failures, paused_user)).to eq(0)
    end
  end

  it "rolls back by removing the three columns and leaving the pause time as it was" do
    paused_user = User.create!(email: "kept@example.com", paused_generation_at: paused_at)

    migrate(:down)

    expect(connection.column_exists?(:daily_exercises, :opened_at)).to be(false)
    expect(connection.column_exists?(:users, :generation_pause_source)).to be(false)
    expect(connection.column_exists?(:users, :generation_account_failures)).to be(false)
    expect(stored(:users, :paused_generation_at, paused_user)).to eq(paused_at)
  ensure
    migrate(:up)
  end
end
