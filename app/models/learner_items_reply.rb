class LearnerItemsReply
  Day = Data.define(:date, :duck_sections, :answered_sections, :note, :explanation_section)
  Item = Data.define(:concept, :bucket, :kind, :term, :label, :evidence)
  Result = Data.define(:items, :dropped)
  Dropped = Class.new(StandardError)

  MAX_ITEMS = LearnerItem::MAX_OPEN + LearnerItem::MAX_NEW_PER_DAY
  REFERENCE_CHARS = 64
  ITEM_FIELD_CHARS = 128
  MAX_ITEM_CHARS = LearnerItem::MAX_LABEL_LENGTH + LearnerItem::MAX_TERM_LENGTH + (LearnerItem::MAX_EVIDENCE * REFERENCE_CHARS) +
                   ITEM_FIELD_CHARS
  MAX_REPLY_CHARS = MAX_ITEMS * MAX_ITEM_CHARS

  def self.parse(raw, day:, buckets:)
    unless raw.is_a?(Hash) && raw["items"].is_a?(Array)
      raise ProviderError::InvalidResponseError, "Learner items reply held no list of items"
    end

    dropped = Hash.new(0)
    items = raw["items"].filter_map do |entry|
      item(entry, day, buckets)
    rescue Dropped => e
      dropped[e.message.to_sym] += 1
      nil
    end
    Result.new(items: items, dropped: dropped.to_h)
  end

  def self.item(entry, day, buckets)
    fields = entry.is_a?(Hash) ? entry.values_at("concept", "bucket", "kind", "label") : []
    drop(:malformed) unless fields.size == 4 && fields.all?(String)

    concept, bucket, kind, label = fields
    drop(:unknown_kind) unless LearnerItem::KINDS.include?(kind)
    drop(:unknown_concept) unless buckets.include?(bucket) && ConceptBucket.valid_identity?(concept: concept, bucket: bucket)

    Item.new(concept: concept, bucket: bucket, kind: kind, term: term(entry["term"], kind), label: label(label),
             evidence: evidence(entry["evidence"], day))
  end

  def self.label(value)
    text = UserText.normalize(value).strip
    drop(:bad_label) if text.empty? || text.length > LearnerItem::MAX_LABEL_LENGTH || text.match?(/[\r\n]/)
    text
  end

  def self.term(value, kind)
    return unless kind == "term"

    term = value.to_s.squish
    drop(:bad_term) unless value.is_a?(String) && term.match?(LearnerItem::TERM_SHAPE)
    term
  end

  def self.evidence(value, day)
    references = Array.wrap(value.is_a?(Array) ? value : nil).filter_map { |reference| reference(reference, day) }.uniq
    drop(:no_evidence) if references.empty?
    references.first(LearnerItem::MAX_EVIDENCE)
  end

  def self.reference(raw, day)
    return unless raw.is_a?(Hash)

    section = raw["section"]
    stamped = { "date" => day.date.iso8601, "source" => raw["source"] }
    case raw["source"]
    when "duck"        then stamped.merge("section" => section) if day.duck_sections.include?(section)
    when "answer"      then stamped.merge("section" => section) if day.answered_sections.include?(section)
    when "note"        then stamped if day.note && section.nil?
    when "explanation" then stamped.merge("section" => day.explanation_section) if explained?(day, section)
    end
  end

  def self.explained?(day, section) = day.explanation_section.present? && (section.nil? || section == day.explanation_section)

  def self.drop(reason) = raise(Dropped, reason.to_s)

  private_class_method :item, :label, :term, :evidence, :reference, :explained?, :drop
end
