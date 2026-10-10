# Re-indents the code a provider wrote, once, at the generation boundary, so
# the page, the grader, the judge and the duck all read the same layout.
# Ruby goes through RuboCop's Layout cops and JavaScript through Prettier.
# Code a formatter cannot parse, such as a Prisma schema or pseudocode, comes
# back unchanged, and so does every snippet when a formatter is unavailable:
# formatting is a nicety and never costs a section.
module CodeFormat
  FORMATTERS = {
    "ruby_rails" => "CodeFormat::Ruby",
    "javascript" => "CodeFormat::Javascript"
  }.freeze

  # The snippets formatted in order, in the day's language. Each keeps its
  # original trailing-newline state, since a formatter always adds one.
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
