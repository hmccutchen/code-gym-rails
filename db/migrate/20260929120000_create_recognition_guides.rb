class CreateRecognitionGuides < ActiveRecord::Migration[8.1]
  def change
    create_table :recognition_guides do |t|
      t.string :group_key, null: false
      t.text :questions, null: false
      t.text :contrast, null: false
      t.text :misfires, null: false

      t.timestamps
    end

    add_index :recognition_guides, :group_key, unique: true
  end
end
