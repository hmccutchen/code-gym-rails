# The parts of AiService::PLAIN_LANGUAGE_STANDARD that code can check. The
# rest of the standard (jargon, active voice, rhythm, forced cleverness) needs
# a reader. Pure, and read by the hand-written Learn text spec and by
# script/compare_concept_lessons.rb.
#
# Two kinds of rule: failures, which plain text never needs (a placeholder
# phrase, every sentence opening the same way), and flags, which point a
# reader at a sentence without proving anything (a "not X, but Y", a long
# sentence, an exclamation point).
module PlainLanguageChecks
  # Read from the standard rather than restated, so a phrase added there is
  # checked here too.
  PLACEHOLDER_PHRASES = AiService::PLAIN_LANGUAGE_STANDARD.lines
                                                         .find { |line| line.include?("Placeholder phrases") }
                                                         .scan(/"([^"]+)"/).flatten
                                                         .map { |phrase| phrase.sub(/[,.]\z/, "").downcase }
                                                         .freeze

  # A sentence past this many words is flagged for a reader to look at, not
  # failed: some long sentences read fine.
  LONG_SENTENCE_WORDS = 35

  # "not X, but Y" within one sentence.
  CONTRAST_PATTERN = /\bnot\b[^.?!]{1,80}?\bbut\b/i

  def self.sentences(text)
    text.split(/(?<=[.?!])\s+/).map(&:strip).reject(&:empty?)
  end

  # The first word stands in for a sentence's construction. That is narrower
  # than the standard's wording, so it only catches the plainest repetition.
  def self.opening_word(sentence)
    sentence[/[[:alpha:]']+/]&.downcase
  end

  def self.words(text)
    text.scan(/[[:alnum:]][[:alnum:]'’-]*/)
  end

  def self.placeholder_hits(text)
    normalized = text.downcase.tr("’", "'")
    PLACEHOLDER_PHRASES.select { |phrase| normalized.include?(phrase) }
  end

  def self.same_opening?(text)
    openings = sentences(text).map { |sentence| opening_word(sentence) }
    openings.size > 1 && openings.uniq.size == 1
  end

  def self.contrast_hits(text)
    sentences(text).grep(CONTRAST_PATTERN)
  end

  def self.long_sentences(text)
    sentences(text).select { |sentence| words(sentence).size > LONG_SENTENCE_WORDS }
  end

  def self.exclamation_count(text)
    text.count("!")
  end

  def self.please_count(text)
    text.scan(/\bplease\b/i).size
  end

  # Every check for one text, as plain values a report can print.
  def self.report(text)
    {
      words: words(text).size,
      placeholder_phrases: placeholder_hits(text),
      same_opening: same_opening?(text),
      contrasts: contrast_hits(text),
      long_sentences: long_sentences(text),
      exclamation_points: exclamation_count(text),
      pleases: please_count(text)
    }
  end
end
