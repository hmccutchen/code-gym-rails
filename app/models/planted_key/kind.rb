# Extended by a section kind that plants a key; each method raising here is one the kind must answer.
module PlantedKey::Kind
  def planted_key? = true

  def normalize_planted_key(_section) = raise(NotImplementedError, "#{self} must implement .normalize_planted_key")

  def key_context_fields = raise(NotImplementedError, "#{self} must implement .key_context_fields")

  def quoted_key_texts(_key) = raise(NotImplementedError, "#{self} must implement .quoted_key_texts")

  def quote_tally(section, language:)
    PlantedKey.quote_tally(quoted_key_texts(section[PlantedKey::FIELD]), within: section.values_at(*key_context_fields),
                           scenario: section["scenario"], language: language)
  end
end
