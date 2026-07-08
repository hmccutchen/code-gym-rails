class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch("MAIL_FROM", "from@example.com")
  layout "mailer"
end
