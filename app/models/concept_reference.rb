class ConceptReference < ApplicationRecord
  validates :concept, :language, presence: true
  validates :concept, uniqueness: { scope: :language }

  # The one answer to "does this row carry the Learn tab's guide". Rows
  # generated before the guide existed answer false, and so does one whose
  # guide the provider left partly blank — both are regenerated whole rather
  # than rendered half-populated. Derived from the field list rather than
  # naming the columns again, the way ConceptBucket derives its vocabulary from
  # AiService::LANGUAGE_CONFIG.
  def guide?
    AiService::CONCEPT_GUIDE_FIELDS.all? { |field| public_send(field).present? }
  end
end
