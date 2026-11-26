require "rails_helper"

migration_path = Rails.root.join("db/migrate/20261120120000_add_slot_to_daily_sets.rb")
require migration_path.to_s

RSpec.describe AddSlotToDailySets do
  let(:connection) { ActiveRecord::Base.connection }
  let(:user) { User.create!(email: "slot-#{SecureRandom.hex(3)}@example.com") }

  around { |example| ActiveRecord::Migration.suppress_messages { example.run } }

  def unique_columns(table) = connection.indexes(table).select(&:unique).map(&:columns)

  it "puts every existing set and response in the first slot" do
    described_class.new.migrate(:down)
    exercise_id = connection.select_value(<<~SQL)
      INSERT INTO daily_exercises (user_id, date, problem_set, generated_at, language, created_at, updated_at)
      VALUES (#{user.id}, CURRENT_DATE, '{}', now(), 'ruby_rails', now(), now()) RETURNING id
    SQL
    connection.execute(<<~SQL)
      INSERT INTO daily_responses (user_id, daily_exercise_id, date, created_at, updated_at)
      VALUES (#{user.id}, #{exercise_id}, CURRENT_DATE, now(), now())
    SQL

    described_class.new.migrate(:up)

    expect(connection.select_values("SELECT slot FROM daily_exercises WHERE id = #{exercise_id}")).to eq([ 1 ])
    expect(connection.select_values("SELECT slot FROM daily_responses WHERE daily_exercise_id = #{exercise_id}")).to eq([ 1 ])
  end

  it "rolls back to one set per user and date" do
    described_class.new.migrate(:down)

    expect(connection.column_exists?(:daily_exercises, :slot)).to be(false)
    expect(connection.column_exists?(:daily_responses, :slot)).to be(false)
    expect(unique_columns(:daily_exercises)).to include(%w[user_id date])
    expect(unique_columns(:daily_responses)).to include(%w[user_id date])
    expect(connection.check_constraints(:daily_exercises).map(&:name)).not_to include("daily_exercises_slot_range")
    expect(connection.check_constraints(:daily_responses).map(&:name)).not_to include("daily_responses_slot_range")
  end

  it "refuses to roll back once a day holds a second set, and changes nothing" do
    insert = lambda do |slot|
      connection.select_value(<<~SQL)
        INSERT INTO daily_exercises (user_id, date, slot, problem_set, generated_at, language, created_at, updated_at)
        VALUES (#{user.id}, CURRENT_DATE, #{slot}, '{}', now(), 'ruby_rails', now(), now()) RETURNING id
      SQL
    end
    insert.call(1)
    insert.call(2)

    expect { described_class.new.migrate(:down) }
      .to raise_error(ActiveRecord::IrreversibleMigration, /second set/)
    expect(connection.column_exists?(:daily_exercises, :slot)).to be(true)
    expect(unique_columns(:daily_exercises)).to include(%w[user_id date slot])
  end

  it "waits at most #{AddSlotToDailySets::LOCK_TIMEOUT} for its table locks in each direction" do
    allow(connection).to receive(:execute).and_call_original

    described_class.new.migrate(:down)
    described_class.new.migrate(:up)

    expect(connection).to have_received(:execute).with("SET LOCAL lock_timeout = '#{AddSlotToDailySets::LOCK_TIMEOUT}'").twice
  end

  it "makes the user, date and slot unique on both tables" do
    expect(unique_columns(:daily_exercises)).to include(%w[user_id date slot])
    expect(unique_columns(:daily_responses)).to include(%w[user_id date slot])
    expect(unique_columns(:daily_exercises)).not_to include(%w[user_id date])
    expect(unique_columns(:daily_responses)).not_to include(%w[user_id date])
  end
end
