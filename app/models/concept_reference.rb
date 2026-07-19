class ConceptReference < ApplicationRecord
  validates :concept, :language, presence: true
  validates :concept, uniqueness: { scope: :language }
end
