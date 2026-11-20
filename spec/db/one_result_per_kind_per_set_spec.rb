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

  it "holds every set's slot to 1 or 2 in the database" do
    %w[daily_exercises daily_responses].each do |table|
      constraint = ActiveRecord::Base.connection.check_constraints(table).find { |candidate| candidate.name == "#{table}_slot_range" }

      expect(constraint&.expression.to_s.delete("()")).to eq("slot >= #{1} AND slot <= #{2}")
    end
  end
end
