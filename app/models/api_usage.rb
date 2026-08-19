class ApiUsage < ApplicationRecord
  belongs_to :user

  PURPOSES = %w[generate_exercise review_response generate_concept_reference explain_differently review_follow_up duck_thread pseudocode_critique pseudocode_translate].freeze
  validates :purpose, inclusion: { in: PURPOSES }
  validates :date, :tokens_in, :tokens_out, presence: true
end
