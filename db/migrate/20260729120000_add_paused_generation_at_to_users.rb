class AddPausedGenerationAtToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :paused_generation_at, :datetime
  end
end
