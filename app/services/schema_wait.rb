# Blocks until the database carries the table the Solid Queue worker reads on
# boot. Run as the worker service's Railway pre-deploy step.
#
# The worker does not own migrations — the web service's pre-deploy step does —
# but Railway starts both services concurrently and orders neither. On a
# pull-request deployment the database starts empty, and `rake solid_queue:start`
# reads REQUIRED_TABLE before it serves anything, so a worker that wins the race
# dies on boot rather than degrading. That is what happened on PR #137, where the
# worker crashed 30 seconds before the web service finished migrating.
#
# **Waiting rather than migrating is the point.** The obvious fix — a second
# `db:migrate`, in this service — is unsafe in precisely the case it targets:
# against an empty database `db:migrate` performs a schema *load*, and a schema
# load takes no advisory lock, so two containers loading concurrently race and
# the loser dies on a duplicate constraint. Migrations keep exactly one owner;
# this only waits for that owner to finish.
class SchemaWait
  REQUIRED_TABLE = "solid_queue_recurring_tasks".freeze
  TIMEOUT = 5.minutes
  POLL_INTERVAL = 5

  class Timeout < StandardError; end

  # Raises rather than returning false on expiry: a pre-deploy command that
  # fails is a deploy that stops loudly, which is the honest outcome when the
  # schema never arrived — better than starting a worker into a crash loop.
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

  # Asks Postgres directly rather than through #table_exists?, whose answer is
  # served from a schema cache loaded before the table existed.
  def self.ready?
    connection = ActiveRecord::Base.connection
    # ::text because the bare regclass OID has no Active Record type mapping,
    # which logs a spurious "unknown OID" warning into the deploy log.
    connection.select_value("SELECT to_regclass(#{connection.quote(REQUIRED_TABLE)})::text").present?
  rescue ActiveRecord::ActiveRecordError
    # The database itself may not be reachable yet on a cold preview
    # environment; that is a wait, not a failure.
    false
  end

  def self.monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
  private_class_method :monotonic_now
end
