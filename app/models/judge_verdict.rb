# The judge's reply, held to its closed vocabulary at the boundary the way
# ProblemSetIngest holds a problem set: a status outside three, an issue type
# or principle outside the lists, a rewritten field outside the kind's prose
# fields, or blank evidence or reason is invalid output, not a judgment. Pure;
# specs need no database.
class JudgeVerdict
  Invalid = Class.new(StandardError)

  ISSUE_TYPES = %w[referential_ambiguity technical_ambiguity unstated_incidental_term leakage padding answer_instruction sequencing].freeze
  PRINCIPLES  = %w[scope_mismatch unstated_prerequisite underdetermined reasoning_failure].freeze
  STATUSES    = %w[keep edit reject].freeze

  attr_reader :status, :issues, :fields, :principle, :evidence, :reason

  def self.parse(raw, kind:)
    raise Invalid, "judge returned #{raw.class}, not an object" unless raw.is_a?(Hash)
    status = raw["status"].to_s
    raise Invalid, "unknown status #{status.inspect}" unless STATUSES.include?(status)

    case status
    when "keep"   then new(status: :keep)
    when "edit"   then parse_edit(raw, kind)
    when "reject" then parse_reject(raw)
    end
  end

  def self.parse_edit(raw, kind)
    issues = Array(raw["issues"]).map { |issue| parse_issue(issue) }
    raise Invalid, "an edit names at least one issue" if issues.empty?
    fields = raw["fields"]
    raise Invalid, "fields must be an object" unless fields.is_a?(Hash) && fields.any?
    fields.each do |name, value|
      raise Invalid, "#{name} is not a prose field of #{kind.key}" unless kind.prose_fields.include?(name)
      raise Invalid, "#{name} rewritten to blank" unless value.is_a?(String) && value.strip.present?
    end
    new(status: :edit, issues: issues, fields: fields)
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
    new(status: :reject, principle: principle,
        evidence: required_text(raw["evidence"], "evidence"), reason: required_text(raw["reason"], "reason"))
  end
  private_class_method :parse_reject

  def self.required_text(value, name)
    raise Invalid, "#{name} must be non-blank text" unless value.is_a?(String) && value.strip.present?
    value.strip
  end
  private_class_method :required_text

  def initialize(status:, issues: [], fields: {}, principle: nil, evidence: nil, reason: nil)
    @status = status
    @issues = issues
    @fields = fields
    @principle = principle
    @evidence = evidence
    @reason = reason
  end

  def reject? = status == :reject
  def edit?   = status == :edit

  # A new section with the rewritten prose in place; the artifact is untouched.
  def apply(section)
    return section unless edit?
    section.merge(fields)
  end
end
