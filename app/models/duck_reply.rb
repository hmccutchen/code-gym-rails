# Design notes: docs/code-notes/app/models/duck_reply.md
class DuckReply < Data.define(:text, :point, :cut)
  POINT_TAG = "Point:"
  POINT_LINE = /(?:\A|\n)[ \t]*#{Regexp.escape(POINT_TAG)}([^\n]*)\z/
  POINT_WORDS = 2..5
  STANDALONE_POINT_LINE = /^[ \t]*#{Regexp.escape(POINT_TAG)}[^\n]*(?:\n|\z)/
  TRAILING_INLINE_POINT = /[ \t]+#{Regexp.escape(POINT_TAG)}[^\n]*\z/

  def self.read(raw, truncated:)
    match = raw.match(POINT_LINE)
    shown = (match ? match.pre_match : raw).gsub(STANDALONE_POINT_LINE, "").rstrip.sub(TRAILING_INLINE_POINT, "")
    raise ProviderError::InvalidResponseError, "Provider returned a duck reply with nothing but its point label" if shown.empty?

    truncated ? new(text: "#{shown}…", point: nil, cut: true) : new(text: shown, point: (point_from(match[1]) if match))
  end

  def initialize(text:, point:, cut: false) = super

  def self.point_from(label)
    words = label.squish.delete_suffix(".").split
    words.join(" ").downcase if POINT_WORDS.cover?(words.size)
  end
  private_class_method :point_from

  def self.with_point(text, point) = point.present? ? "#{text}\n#{POINT_TAG} #{point}" : text

  def self.question?(text) = text.to_s.rstrip.end_with?("?")

  def self.quote_outcome(text, within:, language:)
    quote = text.scan(PlantedKey::QUOTE).flatten.find { |found| PlantedKey.checkable?(found, language) }
    return "none" unless quote

    KeyQuote.normalize(within, language: language).include?(KeyQuote.normalize(quote, language: language)) ? "found" : "missing"
  end

  def question? = self.class.question?(text)
end
