# Design notes: docs/code-notes/app/clients/advisory_lock.md
module AdvisoryLock
  def self.hold(key)
    ActiveRecord::Base.connection_pool.with_connection do |connection|
      next false unless connection.select_value(statement("pg_try_advisory_lock", key))

      begin
        yield
      ensure
        connection.select_value(statement("pg_advisory_unlock", key))
      end
      true
    end
  end

  def self.statement(function, key)
    ActiveRecord::Base.sanitize_sql_array([ "SELECT #{function}(hashtextextended(?, 0))", key ])
  end
end
