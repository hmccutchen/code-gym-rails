# after_initialize: ActionMailer::MailDeliveryJob is not loaded yet when
# initializers first run.
Rails.application.config.after_initialize { PreviewMail.apply! }
