class CreateLearnerNotes < ActiveRecord::Migration[8.1]
  def change
    create_table :learner_notes do |t|
      t.references :user, null: false, foreign_key: true
      t.references :daily_exercise, null: false, foreign_key: true, index: { unique: true }
      t.text :body
      t.string :question_key
      t.string :explain_section
      t.string :explain_concept
      t.string :explain_phrasing
      t.text :explanation
      t.jsonb :explanation_reply
      t.integer :reply_attempts, null: false, default: 0
      t.datetime :reply_requested_at
      t.integer :extract_attempts, null: false, default: 0
      t.datetime :extracted_at
      t.timestamps
      t.check_constraint "extract_attempts BETWEEN 0 AND 2", name: "learner_notes_extract_attempts_range"
      t.check_constraint "reply_attempts BETWEEN 0 AND 2", name: "learner_notes_reply_attempts_range"
    end

    create_table :learner_items do |t|
      t.references :user, null: false, foreign_key: true
      t.string :concept, null: false
      t.string :bucket, null: false
      t.string :kind, null: false
      t.string :label, null: false
      t.string :term
      t.jsonb :evidence, null: false, default: []
      t.jsonb :came_up_on, null: false, default: []
      t.string :status, null: false, default: "open"
      t.date :expires_on, null: false
      t.date :used_on
      t.date :closed_on
      t.date :returned_after
      t.datetime :reopened_at
      t.timestamps
      t.index %i[user_id status]
      t.index "user_id, bucket, concept, kind, lower(coalesce(term, ''))", unique: true, where: "status = 'open'",
        name: "index_learner_items_one_open_per_key"
    end

    add_column :users, :learner_notes_enabled, :boolean, null: false, default: false
  end
end
