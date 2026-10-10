# after_initialize because ActionMailer::MailDeliveryJob is not loaded when initializers first run.
Rails.application.config.after_initialize { PreviewMail.apply! }
