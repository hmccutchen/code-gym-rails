# Delivers mail inline (mail only) because a preview app may run without a worker and login needs the code.
class PreviewMail
  def self.apply!
    return false unless PreviewEnvironment.active?

    ActionMailer::MailDeliveryJob.queue_adapter = :inline
    true
  end
end
