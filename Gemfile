source "https://rubygems.org"

gem "rails", "~> 8.1.4"
gem "propshaft"
gem "pg", "~> 1.7"
gem "puma", ">= 5.0"
gem "importmap-rails"
gem "turbo-rails"
gem "stimulus-rails"
gem "jbuilder"

gem "bcrypt", "~> 3.1.7"

gem "resend"

gem "pagy", "~> 43.7"

gem "rouge", "~> 5.1"

# RealSource slices excerpts with Prism; declared because irb's transitive dependency on it could vanish.
gem "prism", "~> 1.9"

# Needed in production: CodeFormat::Ruby re-indents provider-written Ruby with its Layout cops.
gem "rubocop", require: false

gem "web-push", "~> 3.1"

gem "tzinfo-data", platforms: %i[ windows jruby ]

gem "solid_cache"
gem "solid_queue"
gem "solid_cable"

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

gem "kamal", require: false

gem "thruster", require: false

group :development, :test do
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  gem "rspec-rails", "~> 8.0"

  gem "brakeman", require: false

  gem "rubocop-rails-omakase", require: false

  gem "parallel_tests"
end

group :development do
  gem "web-console"
end

group :test do
  gem "capybara"
  # capybara-playwright-driver's pin must move with playwright-core in spec/playwright/package.json.
  gem "capybara-playwright-driver", "~> 0.5.12"
end

gem "faraday", "~> 2.14"
gem "faraday-retry"
gem "letter_opener", group: :development
