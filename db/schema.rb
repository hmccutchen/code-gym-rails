# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 2026_01_01_000004) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "api_usages", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.integer "tokens_in", default: 0, null: false
    t.integer "tokens_out", default: 0, null: false
    t.string "purpose", null: false
    t.date "date", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id", "date"], name: "index_api_usages_on_user_id_and_date"
    t.index ["user_id"], name: "index_api_usages_on_user_id"
  end

  create_table "daily_exercises", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.date "date", null: false
    t.jsonb "problem_set", default: {}, null: false
    t.datetime "generated_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id", "date"], name: "index_daily_exercises_on_user_id_and_date", unique: true
    t.index ["user_id"], name: "index_daily_exercises_on_user_id"
  end

  create_table "daily_responses", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "daily_exercise_id", null: false
    t.date "date", null: false
    t.jsonb "answers", default: {}, null: false
    t.datetime "submitted_at"
    t.integer "rating"
    t.text "feedback_text"
    t.jsonb "ai_review"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["daily_exercise_id"], name: "index_daily_responses_on_daily_exercise_id"
    t.index ["user_id", "date"], name: "index_daily_responses_on_user_id_and_date", unique: true
    t.index ["user_id"], name: "index_daily_responses_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "email", null: false
    t.string "name", null: false
    t.string "skill_level", default: "developing", null: false
    t.jsonb "focus_areas", default: [], null: false
    t.string "encrypted_api_key"
    t.string "encrypted_api_key_iv"
    t.string "login_token_digest"
    t.datetime "login_token_sent_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["login_token_digest"], name: "index_users_on_login_token_digest"
  end

  add_foreign_key "api_usages", "users"
  add_foreign_key "daily_exercises", "users"
  add_foreign_key "daily_responses", "daily_exercises"
  add_foreign_key "daily_responses", "users"
end
