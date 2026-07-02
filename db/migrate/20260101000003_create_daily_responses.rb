class CreateDailyResponses < ActiveRecord::Migration[8.0]
  def change
    create_table :daily_responses do |t|
      t.references :user,           null: false, foreign_key: true
      t.references :daily_exercise, null: false, foreign_key: true
      t.date       :date,           null: false
      t.jsonb      :answers,        null: false, default: {}
      # answers shape: { code_review: "...", pattern: "...", challenge: "..." }
      t.datetime   :submitted_at
      t.integer    :rating         # 0=too_easy, 1=right_level, 2=too_hard
      t.text       :feedback_text
      t.jsonb      :ai_review      # Claude's inline feedback, stored after /review

      t.timestamps
    end

    add_index :daily_responses, [:user_id, :date], unique: true
  end
end
