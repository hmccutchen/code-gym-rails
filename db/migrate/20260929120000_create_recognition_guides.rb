class CreateRecognitionGuides < ActiveRecord::Migration[8.1]
  def change
    create_table :recognition_guides do |t|
      t.string :group_key, null: false
      t.text :questions
      t.text :contrast
      t.text :misfires

      t.timestamps
    end

    add_index :recognition_guides, :group_key, unique: true
  end
end
