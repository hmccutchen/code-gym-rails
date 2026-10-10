# Formatting never costs a section: unparseable code, or any code when a formatter is unavailable, comes back unchanged.
module CodeFormat
  FORMATTERS = {
    "ruby_rails" => "CodeFormat::Ruby",
    "javascript" => "CodeFormat::Javascript"
  }.freeze

  # Each snippet keeps its original trailing-newline state, since a formatter always adds one.
  def self.all(snippets, language:)
    formatter = FORMATTERS[language]&.constantize
    return snippets unless formatter && snippets.any?

    formatter.all(snippets).zip(snippets).map { |formatted, original| match_ending(formatted || original, original) }
  rescue StandardError => e
    Rails.logger.warn("[code_format] language=#{language} fallback=#{e.class}")
    snippets
  end

  def self.match_ending(formatted, original)
    original.end_with?("\n") ? formatted : formatted.chomp
  end
  private_class_method :match_ending
end
