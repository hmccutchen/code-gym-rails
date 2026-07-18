class ApiUsage < ApplicationRecord
  belongs_to :user

  PURPOSES = %w[generate_exercise review_response generate_concept_reference].freeze
  validates :purpose, inclusion: { in: PURPOSES }
  validates :date, :tokens_in, :tokens_out, presence: true
end
