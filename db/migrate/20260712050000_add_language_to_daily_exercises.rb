# db/migrate/20260712050000_add_language_to_daily_exercises.rb
class AddLanguageToDailyExercises < ActiveRecord::Migration[8.0]
  def change
    add_column :daily_exercises, :language, :string, null: false, default: "ruby_rails"
  end
end
