# Extended by a section kind that plants a key; each method raising here is one the kind must answer.
module PlantedKey::Kind
  def planted_key? = true

  def normalize_planted_key(_section) = raise(NotImplementedError, "#{self} must implement .normalize_planted_key")

  def key_context_fields = raise(NotImplementedError, "#{self} must implement .key_context_fields")

  def quoted_key_texts(_key) = raise(NotImplementedError, "#{self} must implement .quoted_key_texts")

  def unquoted_key_parts(section, language:)
    PlantedKey.unquoted_parts(quoted_key_texts(section[PlantedKey::FIELD]), within: section.values_at(*key_context_fields), language: language)
  end
end
