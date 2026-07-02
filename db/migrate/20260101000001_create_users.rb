class CreateUsers < ActiveRecord::Migration[8.0]
  def change
    create_table :users do |t|
      t.string  :email,               null: false
      t.string  :name,                null: false
      t.string  :skill_level,         null: false, default: "developing"
      t.jsonb   :focus_areas,         null: false, default: []
      t.string  :encrypted_api_key                 # Anthropic key, encrypted at rest
      t.string  :encrypted_api_key_iv
      t.string  :login_token_digest               # BCrypt digest of magic link token
      t.datetime :login_token_sent_at

      t.timestamps
    end

    add_index :users, :email, unique: true
    add_index :users, :login_token_digest
  end
end
