# Design notes: docs/code-notes/app/models/planted_key.md
module PlantedKey
  FIELD = "answer_key".freeze

  MAX_LENGTH = 1_500

  QUOTE = /`([^`]+)`/

  MIN_QUOTE_LENGTH = 3

  def self.text(value)
    value.strip.presence if value.is_a?(String)
  end

  # A cut key could lose the part grading needs, so a field past the limit drops the whole key.
  def self.too_long?(cleaned)
    case cleaned
    when String then cleaned.length > MAX_LENGTH
    when Hash   then cleaned.values.any? { |value| too_long?(value) }
    when Array  then cleaned.any? { |value| too_long?(value) }
    else false
    end
  end

  def self.list(value, max:, &entry)
    value.is_a?(Array) ? value.filter_map(&entry).first(max) : []
  end

  def self.fields(value, names)
    return unless value.is_a?(Hash)

    cleaned = names.index_with { |name| text(value[name]) }
    cleaned if cleaned.values.all?
  end

  GROUNDING = "Every claim in the key must follow from what the engineer is shown, the scenario included, " \
              "and a fact that is itself the planted flaw never appears in the scenario. " \
              "Before you state a consequence, trace it through what is shown, including guards, early returns, locks and validations, " \
              "and never claim an effect they prevent. " \
              "When the flaw depends on a setting that isn't shown and that setting is itself the flaw, phrase the key conditionally, " \
              "for example \"both examples can pass only if the test cache stores nothing, so check which store is used\", " \
              "never assert it as fact, and don't put the setting in backticks.".freeze

  QuoteTally = Data.define(:verbatim, :reference, :scenario, :unresolved) do
    def counts = { verbatim: verbatim, reference: reference, scenario: scenario, unresolved: unresolved.size }

    def unresolved? = unresolved.any?
  end

  def self.hidden_key_line(fields:, before:, quoted:)
    named = fields.map { |field| %("#{field}") }.to_sentence(words_connector: ", ", last_word_connector: " or ")
    quote_rule = " Quote #{quoted} it points at in backticks, never by line number." if quoted
    %(- "answer_key" is HIDDEN test data used only for grading. Never restate, hint at, or echo any of it inside #{named} — ) +
      "doing so would give away the answer before the engineer #{before}.#{quote_rule} #{GROUNDING}"
  end

  def self.unquoted_parts(texts, within:, language:) = quote_tally(texts, within: within, language: language).unresolved

  # A text with no quote at all counts as one miss: the key is asked to quote, so a paraphrase is a lead to read.
  def self.quote_tally(texts, within:, language:, scenario: nil)
    code = within.compact.join("\n")
    outcomes = texts.compact.flat_map do |text|
      quotes = text.scan(QUOTE).flatten
      next [ [ :unresolved, text ] ] if quotes.empty?

      quotes.filter_map { |quote| [ quote_outcome(quote, code, scenario.to_s, language), quote ] if checkable?(quote, language) }
    end
    QuoteTally.new(verbatim: outcomes.count { |outcome, _| outcome == :verbatim },
                   reference: outcomes.count { |outcome, _| outcome == :reference },
                   scenario: outcomes.count { |outcome, _| outcome == :scenario },
                   unresolved: outcomes.filter_map { |outcome, quote| quote if outcome == :unresolved })
  end

  def self.checkable?(quote, language) = KeyQuote.normalize(quote, language: language).length >= MIN_QUOTE_LENGTH

  def self.quote_outcome(quote, code, scenario, language)
    wanted = KeyQuote.normalize(quote, language: language)
    if KeyQuote.normalize(code, language: language).include?(wanted) then :verbatim
    elsif KeyReference.resolves?(quote, code: code, language: language) then :reference
    elsif KeyQuote.normalize(scenario, language: language).include?(wanted) then :scenario
    else :unresolved
    end
  end

  def self.store!(section, cleaned)
    cleaned ? section[FIELD] = cleaned : section.delete(FIELD)
  end

  private_class_method :checkable?, :quote_outcome
end
