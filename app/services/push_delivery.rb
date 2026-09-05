require "web_push"

# Sends one notification to one endpoint, and prunes the endpoint when the push
# service says it is gone.
#
# That pruning is the load-bearing part. iOS drops subscriptions on its own —
# after a stretch of inactivity, or seemingly at random — and a dropped endpoint
# answers 404/410 forever after. Without deleting those rows the reminder job
# spends every morning pushing at addresses that will never deliver again, and
# the delivery log stops meaning anything.
class PushDelivery
  # A push that isn't shown is worse than one not sent: Safari revokes the
  # permission outright if a service worker receives a push and displays
  # nothing. Every payload here therefore carries a title and body, and the
  # service worker shows one unconditionally.
  def self.deliver(subscription, title:, body:, path:)
    return false unless WebPushCredentials.configured?

    WebPush.payload_send(
      message:     JSON.generate(title: title, options: { body: body, data: { path: path } }),
      endpoint:    subscription.endpoint,
      p256dh:      subscription.p256dh_key,
      auth:        subscription.auth_key,
      vapid:       vapid,
      urgency:     "normal"
    )

    subscription.update!(last_delivered_at: Time.current)
    true
  rescue WebPush::ExpiredSubscription, WebPush::InvalidSubscription => e
    Rails.logger.info("[push] pruning dead endpoint for user #{subscription.user_id}: #{e.class}")
    subscription.destroy
    false
  rescue WebPush::ResponseError, Timeout::Error, SocketError, SystemCallError,
         OpenSSL::SSL::SSLError, IOError, Net::HTTPBadResponse => e
    # A transient push-service failure is not the user's problem and not worth a
    # retry storm — tomorrow's reminder is minutes of work away, not hours.
    #
    # The list is this wide because web-push drives Net::HTTP directly and
    # rescues nothing, so a reset connection, a TLS handshake failure or a
    # truncated response arrives here raw. SendPushReminderJob fans out over a
    # user's endpoints in a plain loop, so anything escaping this method would
    # take that user's remaining devices down with the one that failed — the
    # opposite of best-effort. SystemCallError covers every Errno, IOError
    # covers EOFError, and Timeout::Error covers both Net timeouts.
    Rails.logger.warn("[push] delivery failed for user #{subscription.user_id}: #{e.class}: #{e.message}")
    false
  end

  def self.vapid
    {
      subject:     WebPushCredentials.subject,
      public_key:  WebPushCredentials.public_key,
      private_key: WebPushCredentials.private_key
    }
  end
  private_class_method :vapid
end
