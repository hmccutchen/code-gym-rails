# Design notes: docs/code-notes/app/models/planted_key.md
module PlantedKey
  FIELD = "answer_key".freeze

  MAX_LENGTH = 500

  QUOTE = /`([^`]+)`/

  MIN_QUOTE_LENGTH = 3

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

  # A text with no quote at all counts as one miss: the key is asked to quote, so a paraphrase is a lead to read.
  def self.unquoted_parts(texts, within:)
    shown = unspaced(within.compact.join)
    texts.compact.flat_map do |text|
      quotes = text.scan(QUOTE).flatten
      next [ text ] if quotes.empty?

      quotes.select { |quote| unspaced(quote).length >= MIN_QUOTE_LENGTH && shown.exclude?(unspaced(quote)) }
    end
  end

  def self.unspaced(text) = text.gsub(/\s+/, "")

  def self.store!(section, cleaned)
    cleaned ? section[FIELD] = cleaned : section.delete(FIELD)
  end
end
