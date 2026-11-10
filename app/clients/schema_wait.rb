# Waits rather than migrating: db:migrate on an empty database loads the schema unlocked, so two migrators race.
class SchemaWait
  REQUIRED_TABLE = "solid_queue_recurring_tasks".freeze
  TIMEOUT = 5.minutes
  POLL_INTERVAL = 5

  class Timeout < StandardError; end

  # Raises on expiry so the deploy stops loudly instead of starting a worker into a crash loop.
  def self.call(timeout: TIMEOUT, interval: POLL_INTERVAL, logger: Rails.logger)
    deadline = monotonic_now + timeout

    loop do
      if ready?
        logger.info("[schema_wait] #{REQUIRED_TABLE} present")
        return true
      end

      raise Timeout, "#{REQUIRED_TABLE} did not appear within #{timeout.inspect}" if monotonic_now >= deadline

      logger.info("[schema_wait] waiting for #{REQUIRED_TABLE}")
      sleep interval
    end
  end

  # The connection's table_exists? queries pg_class each time; the model-level one reads a schema cache.
  def self.ready?
    ActiveRecord::Base.connection.table_exists?(REQUIRED_TABLE)
  rescue ActiveRecord::ActiveRecordError
    # The database may not be reachable yet on a cold preview environment; that is a wait.
    false
  end

  def self.monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
  private_class_method :monotonic_now
end
