# Forgery protection is off in test; tag an example :with_csrf to turn it on for that example.
RSpec.configure do |config|
  config.around(:each, :with_csrf) do |example|
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    example.run
  ensure
    ActionController::Base.allow_forgery_protection = original
  end
end
