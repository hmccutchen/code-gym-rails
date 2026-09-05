source "https://rubygems.org"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.1.3"
# The modern asset pipeline for Rails [https://github.com/rails/propshaft]
gem "propshaft"
# Use postgresql as the database for Active Record
gem "pg", "~> 1.1"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
# Use JavaScript with ESM import maps [https://github.com/rails/importmap-rails]
gem "importmap-rails"
# Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem "turbo-rails"
# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem "stimulus-rails"
# Build JSON APIs with ease [https://github.com/rails/jbuilder]
gem "jbuilder"

# Login codes are digested with BCrypt (User#generate_login_code!)
gem "bcrypt", "~> 3.1.7"

# Email delivery via Resend's HTTP API (Railway blocks outbound SMTP below Pro)
gem "resend"

# Offset pagination for the History page (HistoryController)
gem "pagy", "~> 43.6"

# VAPID-signed Web Push delivery for the daily reminder (PushDelivery).
# The reminder is best-effort: the gem is only ever reached from a background
# job, so a push failure cannot surface on a request.
gem "web-push", "~> 3.1"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Use the database-backed adapters for Rails.cache, Active Job, and Action Cable
gem "solid_cache"
gem "solid_queue"
gem "solid_cable"

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Deploy this application anywhere as a Docker container [https://kamal-deploy.org]
gem "kamal", require: false

# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem "thruster", require: false

# Use Active Storage variants [https://guides.rubyonrails.org/active_storage_overview.html#transforming-images]
# gem "image_processing", "~> 1.2"

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Testing framework
  gem "rspec-rails", "~> 8.0"

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"
end

group :test do
  # Real-browser system specs, driven by Playwright — kept in its own group
  # (not merged into :development, :test) so neither gem loads outside tests.
  # capybara-playwright-driver is pinned because its playwright-ruby-client
  # dependency must stay compatible with the exact playwright-core CLI version
  # pinned in spec/playwright/package.json — bump the two together.
  gem "capybara"
  gem "capybara-playwright-driver", "~> 0.5.10"
end

gem "faraday", "~> 2.0"
gem "faraday-retry"
gem "letter_opener", group: :development
