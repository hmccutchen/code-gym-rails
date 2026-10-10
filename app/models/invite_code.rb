# Only the digest is kept; the minting script shows the raw code once.
class InviteCode < ApplicationRecord
  CODE_LENGTH = 26
  CODE_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".freeze

  has_many :users, dependent: :nullify

  validates :code_digest, presence: true, uniqueness: true
  validates :seats, numericality: { only_integer: true, greater_than: 0 }
  validates :expires_at, presence: true
  validates :trial_days, numericality: { only_integer: true, greater_than: 0 }
  validates :daily_request_cap, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true

  # Returns the record and the raw code, which is not kept anywhere.
  def self.mint(seats:, expires_at:, trial_days:, label: nil, daily_request_cap: nil)
    code = Array.new(CODE_LENGTH) { CODE_ALPHABET[SecureRandom.random_number(CODE_ALPHABET.size)] }.join
    record = create!(code_digest: digest(code), label: label, seats: seats, expires_at: expires_at,
                     trial_days: trial_days, daily_request_cap: daily_request_cap)
    [ record, code ]
  end

  # Spaces and dashes are allowed when a code is typed, and case is ignored.
  def self.normalize(raw) = raw.to_s.upcase.delete("^A-Z2-7")

  def self.digest(raw) = Digest::SHA256.hexdigest(normalize(raw))

  def self.find_by_code(raw)
    normalized = normalize(raw)
    return if normalized.length != CODE_LENGTH

    find_by(code_digest: digest(normalized))
  end

  # Advisory: #redeem! decides again, since another redemption can take the last seat in between.
  def available? = expires_at.future? && redeemed_count < seats

  # One statement checks seats and deadline together, so two racing redemptions can't both win the last seat.
  def redeem!
    taken = self.class.where(id: id).where("redeemed_count < seats AND expires_at > ?", Time.current)
                .update_all("redeemed_count = redeemed_count + 1")
    reload if taken == 1
    taken == 1
  end
end
