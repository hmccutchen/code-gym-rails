# One push endpoint for one browser install. A user can hold several (a laptop
# and a home-screen iPhone), so the reminder fans out over all of them.
#
# These rows are transport, not intent — `User#push_reminders_enabled` is the
# intent. Keeping them apart is what makes iOS's habit of silently dropping a
# subscription survivable: the endpoint can vanish without the user's answer to
# "do you want reminders" vanishing with it, so the next launch re-registers
# instead of asking again for a permission the browser has already granted.
class PushSubscription < ApplicationRecord
  belongs_to :user

  validates :endpoint, presence: true, uniqueness: true
  validates :p256dh_key, presence: true
  validates :auth_key, presence: true

  # Upsert by endpoint, because the client re-subscribes on every launch and
  # must refresh the row it already has rather than accumulate a duplicate.
  #
  # Reassigns the row when the endpoint arrives under a different user: an
  # endpoint identifies a browser install, and a shared device whose owner has
  # since logged in as someone else must not keep pushing the previous user's
  # reminders to it.
  def self.register!(user:, endpoint:, p256dh_key:, auth_key:)
    subscription = find_or_initialize_by(endpoint: endpoint)
    subscription.update!(user: user, p256dh_key: p256dh_key, auth_key: auth_key)
    subscription
  rescue ActiveRecord::RecordNotUnique
    # Two tabs launching at once both found no row and both inserted. The other
    # one won; retry against the row it created.
    retry
  end
end
