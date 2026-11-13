# Design notes: docs/code-notes/app/clients/advisory_lock.md
module AdvisoryLock
  def self.hold(key)
    ActiveRecord::Base.connection_pool.with_connection do |connection|
      next false unless connection.select_value(statement("pg_try_advisory_lock", key))

      begin
        yield
      ensure
        release(connection, key)
      end
      true
    end
  end

  def self.statement(function, key)
    ActiveRecord::Base.sanitize_sql_array([ "SELECT #{function}(hashtextextended(?, 0))", key ])
  end

  def self.release(connection, key)
    connection.select_value(statement("pg_advisory_unlock", key))
  rescue ActiveRecord::ActiveRecordError => e
    Rails.logger.warn("Could not release advisory lock #{key}: #{e.message}")
  end
  private_class_method :release
end
