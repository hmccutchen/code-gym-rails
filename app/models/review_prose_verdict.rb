# The prose judge's reply about one graded review, held at the boundary the
# way JudgeVerdict holds the section judge's. It may reword the review's prose
# fields and nothing else; every original entry must be cited exactly once,
# so no point is dropped or duplicated. Whether a rewrite keeps an entry's
# meaning is not checkable here and is an accepted risk. Pure; specs need no
# database. Messages never quote provider text, since review text stays out
# of logs.
class ReviewProseVerdict
  Invalid = Class.new(StandardError)

  STATUSES     = %w[keep edit].freeze
  ISSUE_TYPES  = %w[plain_language_violation verbosity].freeze
  ORIGINAL_KEY = "graded_prose"

  attr_reader :status, :issues, :fields

  def self.prose_fields = DailyResponse::AI_REVIEW_FIELDS.keys
  def self.list_field?(field) = DailyResponse::AI_REVIEW_FIELDS.fetch(field)[:list]

  # What the judge is shown, rendered the way the review page renders it.
  # Indexes in a verdict address these lists.
  def self.project(review)
    prose_fields.index_with do |field|
      points = DailyResponse.review_points(review[field])
      list_field?(field) ? points : points.join(" ")
    end
  end

  def self.parse(raw, projection:)
    raise Invalid, "verdict is not an object" unless raw.is_a?(Hash)
    raise Invalid, "unknown status" unless STATUSES.include?(raw["status"])
    return new(status: :keep) if raw["status"] == "keep"

    issues = parse_issues(raw["issues"])
    fields = parse_fields(raw["fields"], projection)
    return new(status: :keep) if fields.empty?

    if merged?(fields) && issues.none? { |issue| issue[:type] == "verbosity" }
      raise Invalid, "a merge needs a verbosity issue"
    end
    new(status: :edit, issues: issues, fields: fields)
  end

  def self.parse_issues(raw)
    raise Invalid, "issues must be a list" unless raw.is_a?(Array)
    raise Invalid, "an edit names at least one issue" if raw.empty?

    raw.map do |issue|
      raise Invalid, "issue must be an object" unless issue.is_a?(Hash)
      raise Invalid, "unknown issue type" unless ISSUE_TYPES.include?(issue["type"])
      { type: issue["type"], evidence: required_text(issue["evidence"], "evidence") }
    end
  end
  private_class_method :parse_issues

  # A rewrite of a field that was empty is dropped, not refused: it has
  # nothing to cite, so it can only be invented, and refusing the verdict
  # would also throw away a sound rewrite of another field.
  def self.parse_fields(raw, projection)
    raise Invalid, "fields must be a non-empty object" unless raw.is_a?(Hash) && raw.any?

    raw.each_with_object({}) do |(field, value), fields|
      raise Invalid, "a rewritten field is not a prose field" unless prose_fields.include?(field)
      next if projection.fetch(field).empty?

      fields[field] = list_field?(field) ? parse_entries(field, value, projection.fetch(field).size) : required_text(value, field)
    end
  end
  private_class_method :parse_fields

  def self.parse_entries(field, value, size)
    raise Invalid, "#{field} must be a list of entries" unless value.is_a?(Array) && value.any?

    entries = value.map { |entry| parse_entry(field, entry) }
    cited   = entries.flat_map { |entry| entry[:from] }
    raise Invalid, "#{field} must cite every original entry exactly once" unless cited.sort == (0...size).to_a

    firsts = entries.map { |entry| entry[:from].first }
    in_place = firsts == firsts.sort && entries.all? { |entry| entry[:from] == entry[:from].sort }
    raise Invalid, "#{field} entries must sit at their earliest source's position" unless in_place

    entries
  end
  private_class_method :parse_entries

  def self.parse_entry(field, entry)
    raise Invalid, "#{field} entry must be an object" unless entry.is_a?(Hash)

    from = entry["from"]
    raise Invalid, "#{field} entry needs a non-empty list of integer indexes" unless from.is_a?(Array) && from.any? && from.all?(Integer)

    { from: from, text: required_text(entry["text"], field) }
  end
  private_class_method :parse_entry

  def self.required_text(value, name)
    raise Invalid, "#{name} must be non-blank text" unless value.is_a?(String) && value.strip.present?

    value.strip
  end
  private_class_method :required_text

  def self.merged?(fields)
    fields.values.any? { |value| value.is_a?(Array) && value.any? { |entry| entry[:from].size > 1 } }
  end
  private_class_method :merged?

  # Structured-output schema from the same lists .parse checks. .parse stays
  # the boundary: the schema cannot say "each index exactly once", bound a
  # string's length, or require a non-empty issues, fields or from list.
  def self.schema
    VerdictSchema.one_per_status(STATUSES) { |status| shape_for(status) }
  end

  def self.shape_for(status)
    return {} if status == "keep"

    text   = { "type" => "string" }
    entry  = VerdictSchema.closed_object({ "from" => { "type" => "array", "items" => { "type" => "integer" } }, "text" => text })
    issue  = VerdictSchema.closed_object({ "type" => { "type" => "string", "enum" => ISSUE_TYPES }, "evidence" => text })
    fields = prose_fields.index_with { |field| list_field?(field) ? { "type" => "array", "items" => entry } : text }
    { "issues" => { "type" => "array", "items" => issue }, "fields" => VerdictSchema.closed_object(fields, required: []) }
  end
  private_class_method :shape_for

  def initialize(status:, issues: [], fields: {})
    @status = status
    @issues = issues
    @fields = fields
  end

  def edit? = status == :edit

  def merges
    fields.filter_map do |field, value|
      next unless value.is_a?(Array)

      merged = value.map { |entry| entry[:from] }.select { |from| from.size > 1 }
      [ field, merged ] if merged.any?
    end.to_h
  end

  # The rewrite in place, with the grader's prose kept under ORIGINAL_KEY
  # exactly as returned so a later audit can compare the two.
  def apply(review)
    return review unless edit?

    rewritten = fields.transform_values { |value| value.is_a?(Array) ? value.map { |entry| entry[:text] } : value }
    review.merge(rewritten).merge(ORIGINAL_KEY => review.slice(*self.class.prose_fields))
  end
end
