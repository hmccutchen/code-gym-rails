ActiveRecord::Schema[8.1].define(version: 1) do
  create_table "users", force: :cascade do |t|
    t.string "email", null: false
  end
end
