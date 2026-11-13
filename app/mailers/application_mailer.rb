class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch("MAIL_FROM", "from@example.com")
  layout "mailer"

  # A record named in a queued mail was deleted with its account; raising would keep the job as a failed one forever.
  rescue_from ActiveJob::DeserializationError do |error|
    Rails.logger.info("Dropped a queued mail: #{error.cause.class} for a record that no longer exists")
  end
end
