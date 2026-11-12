RSpec.configure do |config|
  # The fixture rollback undoes the spec's schema changes, so plans prepared against them would fail the next file.
  config.after(file_path: %r{spec/migrations/}) { ActiveRecord::Base.connection.clear_cache! }
end
