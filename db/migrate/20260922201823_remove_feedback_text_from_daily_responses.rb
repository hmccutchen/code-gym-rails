class RemoveFeedbackTextFromDailyResponses < ActiveRecord::Migration[8.1]
  def change
    remove_column :daily_responses, :feedback_text, :text
  end
end
