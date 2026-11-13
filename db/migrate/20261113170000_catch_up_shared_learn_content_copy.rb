# Reasoning in docs/code-notes/db/migrate/20261113170000_catch_up_shared_learn_content_copy.md.
require_relative "20261113150000_copy_shared_learn_content"

class CatchUpSharedLearnContentCopy < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    CopySharedLearnContent.copy_to_active_users(connection)
  end

  def down; end
end
