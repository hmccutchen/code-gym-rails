# allow_forgery_protection is off app-wide in test (config/environments/test.rb).
# Tag an example :with_csrf to turn it on for that example's duration only —
# needed for specs that exercise the real CSRF path (a stale/garbage token,
# or a real browser reading the csrf_meta_tags the dashboard's inline script
# depends on).
RSpec.configure do |config|
  config.around(:each, :with_csrf) do |example|
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    example.run
  ensure
    ActionController::Base.allow_forgery_protection = original
  end
end
