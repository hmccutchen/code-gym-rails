require "active_support/configuration_file"

# The connection pool size config/database.yml asks for, per process.
#
# A Solid Queue worker thread can be running the judged generation
# (AiService#generate_judged_exercise). Its judge and retry fan-outs each start
# one thread per section, and each of those checks out a connection to write
# its ApiUsage row, on top of the one the job thread may already hold. Solid
# Queue's own polling and heartbeat take two more. The default pool of 5 held
# the worker threads alone, so a judge thread could wait out the checkout
# timeout at the point it records a call the provider already billed. Sized
# this way, the fan-out never waits for a connection.
#
# The cron batch generates one user at a time, so three judged generations at
# once needs three overlapping hourly runs. The pool is sized for it anyway:
# connections open only when a thread asks for one, so a larger ceiling costs
# nothing until it is used.
#
# SECTIONS_PER_DAY restates ExerciseSection.slot_count because database.yml is
# read during boot, before app/ can be autoloaded; a spec holds the two equal.
# Worker threads are read from config/queue.yml, which is plain configuration.
# Lives in lib/boot for the same reason AppHost does.
module DatabasePool
  SECTIONS_PER_DAY = 4
  SOLID_QUEUE_OWN_CONNECTIONS = 2
  DEFAULT_THREADS = 5

  QUEUE_CONFIG = File.expand_path("../../config/queue.yml", __dir__)

  def self.size(rails_env, env = ENV)
    [ Integer(env.fetch("RAILS_MAX_THREADS", DEFAULT_THREADS)), judged_worker_connections(rails_env) ].max
  end

  def self.judged_worker_connections(rails_env)
    worker_threads(rails_env) * (1 + SECTIONS_PER_DAY) + SOLID_QUEUE_OWN_CONNECTIONS
  end
  private_class_method :judged_worker_connections

  def self.worker_threads(rails_env)
    ActiveSupport::ConfigurationFile.parse(QUEUE_CONFIG)
      .fetch(rails_env).fetch("workers").map { |worker| worker.fetch("threads") }.max
  end
  private_class_method :worker_threads
end
