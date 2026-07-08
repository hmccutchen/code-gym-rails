class CreateApiUsages < ActiveRecord::Migration[8.0]
  def change
    create_table :api_usages do |t|
      t.references :user,       null: false, foreign_key: true
      t.integer    :tokens_in,  null: false, default: 0
      t.integer    :tokens_out, null: false, default: 0
      t.string     :purpose,    null: false  # 'generate_exercise' | 'review_response'
      t.date       :date,       null: false

      t.timestamps
    end

    add_index :api_usages, [ :user_id, :date ]
  end
end
