require "rails_helper"

RSpec.describe "One result per kind per set" do
  # Two slots can share a date, so LevelSuggestion's window counts separate days only through its own uniq by date.
  %w[
    daily_exercises:index_daily_exercises_on_user_id_and_date_and_slot
    daily_responses:index_daily_responses_on_user_id_and_date_and_slot
    daily_responses:index_daily_responses_on_daily_exercise_id
  ].each do |entry|
    table, name = entry.split(":")

    it "keeps #{name} unique" do
      index = ActiveRecord::Base.connection.indexes(table).find { |candidate| candidate.name == name }

      expect(index).to be_present
      expect(index.unique).to be(true)
    end
  end

  describe "the slot rules, on rows" do
    let(:connection) { ActiveRecord::Base.connection }
    let(:user) { User.create!(email: "slot-rows-#{SecureRandom.hex(3)}@example.com") }

    def insert_exercise(slot)
      connection.select_value(<<~SQL)
        INSERT INTO daily_exercises (user_id, date, slot, problem_set, generated_at, language, created_at, updated_at)
        VALUES (#{user.id}, CURRENT_DATE, #{slot}, '{}', now(), 'ruby_rails', now(), now()) RETURNING id
      SQL
    end

    def insert_response(exercise_id, slot)
      connection.execute(<<~SQL)
        INSERT INTO daily_responses (user_id, daily_exercise_id, date, slot, created_at, updated_at)
        VALUES (#{user.id}, #{exercise_id}, CURRENT_DATE, #{slot}, now(), now())
      SQL
    end

    it "accepts a second set and its response beside the first on one date" do
      first = insert_exercise(1)
      second = insert_exercise(2)

      expect { insert_response(first, 1) }.not_to raise_error
      expect { insert_response(second, 2) }.not_to raise_error
    end

    it "refuses two sets or two responses in one slot of a date" do
      first = insert_exercise(1)
      other = insert_exercise(2)
      insert_response(first, 1)

      expect { connection.transaction(requires_new: true) { insert_exercise(1) } }.to raise_error(ActiveRecord::RecordNotUnique)
      expect { connection.transaction(requires_new: true) { insert_response(other, 1) } }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    [ 0, 3 ].each do |slot|
      it "refuses slot #{slot} on both tables" do
        first = insert_exercise(1)

        expect { connection.transaction(requires_new: true) { insert_exercise(slot) } }
          .to raise_error(ActiveRecord::StatementInvalid, /daily_exercises_slot_range/)
        expect { connection.transaction(requires_new: true) { insert_response(first, slot) } }
          .to raise_error(ActiveRecord::StatementInvalid, /daily_responses_slot_range/)
      end
    end
  end
end
