class AddLastGenerationErrorToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :last_generation_error_date, :date
    add_column :users, :last_generation_error, :string
  end
end
