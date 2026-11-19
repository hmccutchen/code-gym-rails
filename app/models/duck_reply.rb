# Design notes: docs/code-notes/app/models/duck_reply.md
class DuckReply < Data.define(:text, :point)
  POINT_LINE = /(?:\A|\n)[ \t]*Point:([^\n]*)\z/
  POINT_WORDS = 2..5

  def self.read(raw, truncated:)
    match = raw.match(POINT_LINE)
    shown = (match ? match.pre_match : raw).rstrip
    raise ProviderError::InvalidResponseError, "Provider returned a duck reply with nothing but its point label" if shown.empty?

    truncated ? new(text: "#{shown}…", point: nil) : new(text: shown, point: (point_from(match[1]) if match))
  end

  def self.point_from(label)
    words = label.squish.delete_suffix(".").split
    words.join(" ").downcase if POINT_WORDS.cover?(words.size)
  end
  private_class_method :point_from

  def self.question?(text) = text.to_s.rstrip.end_with?("?")

  def self.quote_outcome(text, within:, language:)
    quote = text.scan(PlantedKey::QUOTE).flatten.find { |found| PlantedKey.checkable?(found, language) }
    return "none" unless quote

    KeyQuote.normalize(within, language: language).include?(KeyQuote.normalize(quote, language: language)) ? "found" : "missing"
  end

  def question? = self.class.question?(text)
end
