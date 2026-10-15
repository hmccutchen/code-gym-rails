require "rails_helper"

RSpec.describe "One result per kind per day" do
  # TrackGraduation's five-result window counts five separate days only because these hold.
  %w[
    daily_exercises:index_daily_exercises_on_user_id_and_date
    daily_responses:index_daily_responses_on_user_id_and_date
    daily_responses:index_daily_responses_on_daily_exercise_id
  ].each do |entry|
    table, name = entry.split(":")

    it "keeps #{name} unique" do
      index = ActiveRecord::Base.connection.indexes(table).find { |candidate| candidate.name == name }

      expect(index).to be_present
      expect(index.unique).to be(true)
    end
  end
end
