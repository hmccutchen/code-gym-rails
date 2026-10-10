require "active_support/configuration_file"

# Sized so a judge fan-out never waits for a connection; see CLAUDE.md, "Railway Deployment".
module DatabasePool
  # Restates ExerciseSection::MAX_SECTIONS, which cannot autoload at boot; a spec holds the two equal.
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
