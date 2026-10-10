require "web_push"

# Pruning gone endpoints (404/410) matters: iOS drops subscriptions on its own and they never deliver again.
class PushDelivery
  # Every payload carries a title and body: Safari revokes permission if a worker gets a push and shows nothing.
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
    # Rescued wide because web-push rescues nothing and an escape would skip the user's other endpoints.
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
