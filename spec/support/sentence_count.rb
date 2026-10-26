module SentenceCount
  ABBREVIATION = /\b(e\.g|i\.e)\./i
  SENTENCE_END = /[.!?](?=\s+[A-Z])/

  def self.split(text)
    text.gsub(ABBREVIATION, "").split(SENTENCE_END).map(&:strip).reject(&:empty?)
  end

  def self.of(text)
    split(text).size
  end
end
