# Transport, not intent (User#reminder_level), so iOS dropping an endpoint doesn't lose the user's answer.
class PushSubscription < ApplicationRecord
  belongs_to :user

  validates :endpoint, presence: true, uniqueness: true
  validates :p256dh_key, presence: true
  validates :auth_key, presence: true

  # Upserts and reassigns to the current user; the SAVEPOINT in #upsert lets a racing tab retry inside a caller's transaction.
  def self.register!(user:, endpoint:, p256dh_key:, auth_key:)
    upsert(user: user, endpoint: endpoint, p256dh_key: p256dh_key, auth_key: auth_key)
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
    raise if e.is_a?(ActiveRecord::RecordInvalid) && e.record.errors[:endpoint].blank?

    upsert(user: user, endpoint: endpoint, p256dh_key: p256dh_key, auth_key: auth_key)
  end

  def self.upsert(user:, endpoint:, p256dh_key:, auth_key:)
    transaction(requires_new: true) do
      find_or_initialize_by(endpoint: endpoint)
        .tap { |subscription| subscription.update!(user: user, p256dh_key: p256dh_key, auth_key: auth_key) }
    end
  end
  private_class_method :upsert
end
