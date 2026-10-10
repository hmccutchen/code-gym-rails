require_relative "boot"
require_relative "../lib/boot/database_pool"

require "rails"
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
require "action_mailbox/engine"
require "action_text/engine"
require "action_view/railtie"
require "action_cable/engine"

Bundler.require(*Rails.groups)

module CodeGymRails
  class Application < Rails::Application
    config.load_defaults 8.0

    # config/environments requires lib/boot directly, where autoloading raises, so Zeitwerk must not manage it.
    config.autoload_lib(ignore: %w[assets tasks boot rubocop])

    config.generators.system_tests = nil
  end
end
