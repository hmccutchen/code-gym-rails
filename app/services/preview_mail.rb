# A preview app may run web-only. Magic-link login is the only way in and ships
# via deliver_later, so mail must not depend on a worker draining the queue.
# Mail only: every other job class keeps the configured adapter, so the app
# under review behaves like production everywhere the reviewer is looking.
class PreviewMail
  def self.apply!
    return false unless PreviewEnvironment.active?

    ActionMailer::MailDeliveryJob.queue_adapter = :inline
    true
  end
end
