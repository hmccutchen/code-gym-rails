# Reasoning in docs/code-notes/db/migrate/20261113150000_copy_shared_learn_content.md.
class CopySharedLearnContent < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def self.copy_to_active_users(connection)
    raise ArgumentError, "#{name} must run outside a transaction: declare disable_ddl_transaction!" if connection.transaction_open?

    connection.select_values("SELECT id FROM users WHERE anonymized_at IS NULL ORDER BY id").each do |user_id|
      connection.transaction { copy_to(connection, Integer(user_id)) }
    end
  end

  def self.copy_to(connection, user_id)
    return unless connection.select_value("SELECT 1 FROM users WHERE id = #{user_id} AND anonymized_at IS NULL FOR SHARE")

    owner_keys.each { |table, key| connection.execute(copy_sql(connection, table, key, user_id)) }
  end

  def self.owner_keys
    { "concept_references" => %w[user_id concept language], "recognition_guides" => %w[user_id group_key] }
  end

  private_class_method :owner_keys

  def self.copy_sql(connection, table, key, user_id)
    columns = (connection.columns(table).map(&:name) - %w[id user_id]).map { |name| connection.quote_column_name(name) }.join(", ")

    <<~SQL
      INSERT INTO #{table} (user_id, #{columns})
      SELECT #{user_id}, #{columns} FROM #{table} WHERE user_id IS NULL
      ON CONFLICT (#{key.join(', ')}) DO NOTHING
    SQL
  end

  private_class_method :copy_sql

  def up
    self.class.copy_to_active_users(connection)
  end

  def down; end
end
