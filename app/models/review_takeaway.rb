class ReviewTakeaway
  ESSENTIAL_GAPS = "essential_gaps"
  MAX_LENGTH = 400
  PARAGRAPH_BREAK = /[\r\n\u0085\u2028\u2029]/
  CONTEXT_POINTER = /\b(?:above|below|as noted|as discussed|the former|the latter)\b/i
  NON_DECLARATIVE = /[?!]|<(?:\/?[a-z]|[!?])[^>]*>/i
  PROSE_WORD = /[[:alpha:]]+(?:['’-][[:alpha:]]+)*/

  def self.call(response, section)
    return unless response.submitted? && response.ai_review.is_a?(Hash)

    kind = ExerciseSection.find(section)
    return if kind.nil? || kind.rating_fixed?

    review = response.ai_review[section.to_s]
    return unless ReviewedSectionResults.current_rubric?(review) && response.ai_rating_unfavorable?(section)

    displayed = missed_slots(review["missed"])
    return unless displayed && positions_beside_original?(review)

    entry = essential_entry(ReviewProseVerdict.as_graded(review))
    return unless entry && displayed.count { |slot| slot.strip == entry } == 1

    entry if compact_prose?(entry)
  end

  def self.positions_beside_original?(review)
    audit_key = ReviewProseVerdict::ORIGINAL_KEY
    return review.key?(ESSENTIAL_GAPS) unless review.key?(audit_key)

    original = review[audit_key]
    allowed_fields = ReviewProseVerdict.prose_fields + [ ESSENTIAL_GAPS ]
    return false unless original.is_a?(Hash) && original.key?("missed") && (original.keys - allowed_fields).empty?

    if original["missed"] == review["missed"]
      review.key?(ESSENTIAL_GAPS) && !original.key?(ESSENTIAL_GAPS)
    else
      original.key?(ESSENTIAL_GAPS) && !review.key?(ESSENTIAL_GAPS)
    end
  end
  private_class_method :positions_beside_original?

  def self.essential_entry(review)
    slots = missed_slots(review["missed"])
    return unless slots

    check = RubricCheck.new(review)
    return unless check.agrees? && check.essential_gaps.one?

    entry = slots.fetch(check.essential_gaps.first).strip
    String.new(entry) if entry.present?
  end
  private_class_method :essential_entry

  def self.missed_slots(value)
    return [ value ] if value.is_a?(String)

    value if value.is_a?(Array) && value.all?(String)
  end
  private_class_method :missed_slots

  def self.compact_prose?(entry)
    return false if entry.length > MAX_LENGTH || entry.match?(PARAGRAPH_BREAK) || !entry.end_with?(".")

    prose = mask_inline_code(entry)
    return false if prose.nil? || prose.match?(NON_DECLARATIVE) || prose.match?(CONTEXT_POINTER)

    sentences = prose.delete_suffix(".").split(/\. +/, -1)
    sentences.size.between?(1, 2) && sentences.all? { |sentence| sentence_candidate?(sentence) }
  end
  private_class_method :compact_prose?

  def self.mask_inline_code(text)
    segments = text.split("`", -1)
    return unless segments.size.odd?

    segments.each_with_index do |segment, index|
      next if index.even?
      return if segment.blank?

      segments[index] = "`"
    end
    segments.join
  end
  private_class_method :mask_inline_code

  def self.sentence_candidate?(sentence)
    sentence.match?(/\A[[:upper:]`]/) && !sentence.start_with?("This ", "That ", "It ") &&
      !sentence.include?(".") && sentence.scan(PROSE_WORD).size >= 3
  end
  private_class_method :sentence_candidate?
end
