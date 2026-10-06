# One invite: how many accounts it admits, by when, and whether each starts a
# trial on a house key. The raw code is shown once, by the minting script,
# and only its digest is kept, so no page or row can give a code away.
class InviteCode < ApplicationRecord
  CODE_LENGTH = 26
  CODE_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".freeze

  has_many :users, dependent: :nullify

  validates :code_digest, presence: true, uniqueness: true
  validates :seats, numericality: { only_integer: true, greater_than: 0 }
  validates :expires_at, presence: true
  validates :provider, inclusion: { in: ->(_) { InviteCode.trial_providers } }, allow_nil: true
  validates :trial_days, numericality: { only_integer: true, greater_than: 0 }, if: :trial?
  validates :daily_request_cap, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true

  # A trial runs only on a provider whose data notice exists, since consent is
  # given to that notice; the test provider counts where it is available.
  def self.trial_providers
    AiProvider.all.select { |provider| provider.available? && I18n.exists?("trials.data_notice.#{provider.provider_key}") }
              .map(&:provider_key)
  end

  # Returns the record and the raw code, which is not kept anywhere.
  def self.mint(seats:, expires_at:, label: nil, provider: nil, trial_days: nil, daily_request_cap: nil)
    code = Array.new(CODE_LENGTH) { CODE_ALPHABET[SecureRandom.random_number(CODE_ALPHABET.size)] }.join
    record = create!(code_digest: digest(code), label: label, provider: provider, seats: seats,
                     expires_at: expires_at, trial_days: trial_days, daily_request_cap: daily_request_cap)
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

  def trial? = provider.present?

  # Takes one seat, or none: a single statement decides against the seat count
  # and the deadline together, so two redemptions racing for the last seat
  # cannot both win.
  def redeem!
    taken = self.class.where(id: id).where("redeemed_count < seats AND expires_at > ?", Time.current)
                .update_all("redeemed_count = redeemed_count + 1")
    reload if taken == 1
    taken == 1
  end
end
