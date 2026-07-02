class ApiUsage < ApplicationRecord
  belongs_to :user

  PURPOSES = %w[generate_exercise review_response].freeze
  validates :purpose, inclusion: { in: PURPOSES }
  validates :date, :tokens_in, :tokens_out, presence: true

  scope :this_month, -> { where(date: Date.current.beginning_of_month..Date.current.end_of_month) }

  def self.summary_by_user(month = Date.current)
    range = month.beginning_of_month..month.end_of_month
    where(date: range)
      .joins(:user)
      .group("users.name", "users.email")
      .select("users.name, users.email, SUM(tokens_in + tokens_out) AS total_tokens")
      .order("total_tokens DESC")
  end
end
