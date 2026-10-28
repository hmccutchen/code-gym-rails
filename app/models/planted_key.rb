# Design notes: docs/code-notes/app/models/planted_key.md
module PlantedKey
  FIELD = "answer_key".freeze

  MAX_LENGTH = 500

  def self.text(value)
    value.strip.truncate(MAX_LENGTH).presence if value.is_a?(String)
  end

  def self.list(value, max:, &entry)
    value.is_a?(Array) ? value.filter_map(&entry).first(max) : []
  end

  def self.fields(value, names)
    return unless value.is_a?(Hash)

    cleaned = names.index_with { |name| text(value[name]) }
    cleaned if cleaned.values.all?
  end

  def self.store!(section, cleaned)
    cleaned ? section[FIELD] = cleaned : section.delete(FIELD)
  end
end
