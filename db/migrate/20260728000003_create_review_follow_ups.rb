class CreateReviewFollowUps < ActiveRecord::Migration[8.0]
  def change
    create_table :review_follow_ups do |t|
      t.references :daily_response, null: false, foreign_key: true
      t.string  :section, null: false
      t.integer :role,    null: false
      t.text    :content, null: false
      t.timestamps
    end
    add_index :review_follow_ups, [ :daily_response_id, :section, :created_at ],
              name: "index_review_follow_ups_on_response_section_created"
  end
end
