# Boundary for the judge's reply, like ProblemSetIngest; no error message quotes the blind solve, an answer candidate.
class JudgeVerdict
  Invalid = Class.new(StandardError)

  ISSUE_TYPES = %w[referential_ambiguity technical_ambiguity unstated_incidental_term leakage padding answer_instruction sequencing].freeze
  PRINCIPLES  = %w[scope_mismatch unstated_prerequisite underdetermined reasoning_failure].freeze
  STATUSES    = %w[keep edit reject].freeze
  SOLVE_FIELD = "better".freeze

  attr_reader :status, :issues, :fields, :principle, :evidence, :reason, :solve

  def self.parse(raw, kind:)
    raise Invalid, "judge returned #{raw.class}, not an object" unless raw.is_a?(Hash)
    status = raw["status"].to_s
    raise Invalid, "unknown status #{status.inspect}" unless STATUSES.include?(status)

    attributes =
      case status
      when "keep"   then {}
      when "edit"   then parse_edit(raw, kind)
      when "reject" then parse_reject(raw)
      end
    new(status: status.to_sym, solve: parse_solve(raw, kind), **attributes)
  end

  # The schema can't bound strings or require non-empty lists, so .parse stays the boundary.
  def self.schema_for(kind)
    VerdictSchema.one_per_status(STATUSES) { |status| shape_for(status, kind).merge(solve_shape(kind)) }
  end

  def self.solve_shape(kind)
    options = kind.judge_solve_options
    options ? { SOLVE_FIELD => { "type" => "string", "enum" => options } } : {}
  end
  private_class_method :solve_shape

  def self.shape_for(status, kind)
    text = { "type" => "string" }
    case status
    when "keep"   then {}
    when "edit"
      issue  = VerdictSchema.closed_object({ "type" => { "type" => "string", "enum" => ISSUE_TYPES }, "evidence" => text })
      fields = VerdictSchema.closed_object(kind.prose_fields.index_with { text }, required: [])
      { "issues" => { "type" => "array", "items" => issue }, "fields" => fields }
    when "reject" then { "principle" => { "type" => "string", "enum" => PRINCIPLES }, "evidence" => text, "reason" => text }
    end
  end
  private_class_method :shape_for

  def self.parse_edit(raw, kind)
    issues = Array(raw["issues"]).map { |issue| parse_issue(issue) }
    raise Invalid, "an edit names at least one issue" if issues.empty?
    fields = raw["fields"]
    raise Invalid, "fields must be an object" unless fields.is_a?(Hash) && fields.any?
    fields.each do |name, value|
      raise Invalid, "#{name} is not a prose field of #{kind.key}" unless kind.prose_fields.include?(name)
      raise Invalid, "#{name} rewritten to blank" unless value.is_a?(String) && value.strip.present?
    end
    { issues: issues, fields: fields }
  end
  private_class_method :parse_edit

  def self.parse_issue(issue)
    raise Invalid, "issue must be an object" unless issue.is_a?(Hash)
    type = issue["type"].to_s
    raise Invalid, "unknown issue type #{type.inspect}" unless ISSUE_TYPES.include?(type)
    { type: type, evidence: required_text(issue["evidence"], "evidence") }
  end
  private_class_method :parse_issue

  def self.parse_reject(raw)
    principle = raw["principle"].to_s
    raise Invalid, "unknown principle #{principle.inspect}" unless PRINCIPLES.include?(principle)
    { principle: principle, evidence: required_text(raw["evidence"], "evidence"), reason: required_text(raw["reason"], "reason") }
  end
  private_class_method :parse_reject

  def self.parse_solve(raw, kind)
    options = kind.judge_solve_options
    return if options.nil?
    raise Invalid, "a #{kind.key} verdict must name one of #{options.join(', ')} as #{SOLVE_FIELD}" unless options.include?(raw[SOLVE_FIELD])

    raw[SOLVE_FIELD]
  end
  private_class_method :parse_solve

  def self.required_text(value, name)
    raise Invalid, "#{name} must be non-blank text" unless value.is_a?(String) && value.strip.present?
    value.strip
  end
  private_class_method :required_text

  def initialize(status:, issues: [], fields: {}, principle: nil, evidence: nil, reason: nil, solve: nil)
    @status = status
    @issues = issues
    @fields = fields
    @principle = principle
    @evidence = evidence
    @reason = reason
    @solve = solve
  end

  def reject? = status == :reject
  def edit?   = status == :edit

  # A new section with the rewritten prose in place; the artifact is untouched.
  def apply(section)
    return section unless edit?
    section.merge(fields)
  end
end
