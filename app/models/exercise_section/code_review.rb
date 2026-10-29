# Design notes: docs/code-notes/app/models/exercise_section/code_review.md
class ExerciseSection::CodeReview < ExerciseSection
  extend PlantedKey::Kind

  KEY_FIELDS = %w[issue why_it_matters fix].freeze

  MAX_SNIPPET_LINES = RealSource::MAX_LINES

  def self.key_context_fields = %w[snippet current_schema]

  def self.quoted_key_texts(key) = [ key&.dig("issue") ]

  def self.normalize_planted_key(section) = PlantedKey.fields(section[PlantedKey::FIELD], KEY_FIELDS)

  def self.refusal_codes = %w[snippet_missing snippet_too_long]

  def self.reject_unusable!(section)
    snippet = section["snippet"]
    refuse!("snippet_missing", "Code review returned no usable snippet") unless snippet.is_a?(String) && snippet.strip.present?

    lines = shown_lines(snippet)
    return if lines <= MAX_SNIPPET_LINES

    refuse!("snippet_too_long", "Code review snippet runs #{lines} lines, past #{MAX_SNIPPET_LINES}")
  end

  def self.diagrammable?
    true
  end

  def self.titled_label?
    false
  end

  def self.default_daily?
    true
  end

  def self.judge_task
    "Find the one planted issue in the snippet and say how to fix it."
  end

  def self.discovery?
    true
  end

  def self.code_fields
    %w[snippet]
  end

  def self.prose_fields
    %w[scenario question teaching_note]
  end

  # A RealSource excerpt's own instruction replaces the mode's toy line.
  def self.generation_guidance(vocabulary:, label:, mode: nil, artifact: nil, test_framework: nil, source: nil, **)
    <<~GUIDANCE.chomp
      #{source ? source.instruction : content_instruction(label, mode, artifact, test_framework)}
      - Choose the code_review concept from this vocabulary, exactly one: #{vocabulary.join(", ")}
      - "answer_key" is HIDDEN test data used only for grading. Never restate, hint at, or echo any of it inside "question", "scenario", "teaching_note" or "diagram" — doing so would give away the answer before the engineer reads the snippet. Quote the code it points at in backticks, never by line number.
    GUIDANCE
  end

  def self.content_instruction(label, mode, artifact, test_framework)
    case mode
    when :test_file
      "- The code_review snippet must be #{test_framework} #{label} test file — a realistic test file exhibiting one real test smell, same question shape (\"what's the issue here, and how would you fix it\")."
    when :schema_review
      "- The code_review snippet must be #{artifact}, ~10-15 lines, containing one planted data-modeling flaw. Same question shape as any other code_review (\"what's the issue here, and how would you fix it\") — the engineer reviews the proposed change, not prose about it."
    else
      "- The code_review snippet must be realistic #{label} code — not toy examples."
    end
  end
  private_class_method :content_instruction

  # Keep the snippet's language out of here: the instruction line above is its one authoritative statement.
  def self.schema_fragment(label:)
    <<~SCHEMA.chomp
      "code_review": {
          "question": "string — what to find/fix",
          "snippet":  "string — ~10-15 lines, matching the code_review snippet instruction above",
          "teaching_note": "string — 1-2 sentence hint toward the key insight, never the answer",
          "concept": "string — exactly one concept from the provided vocabulary",
          "scenario": "string — the concrete business-domain framing, e.g. 'inventory restocking service'",
          "diagram":  "string — Mermaid source showing the structure this snippet describes, or an empty string if no diagram would help",
          "answer_key": {
            "issue":          "string — what is wrong and where, quoting the code in backticks",
            "why_it_matters": "string — what goes wrong because of it in this code",
            "fix":            "string — a fix that works as written"
          }
        }
    SCHEMA
  end

  def self.grading_note(section:, answer:)
    "Main point: the one planted issue — the defect in the snippet, the smell in the test file, or the flaw in the migration.\n" \
    "Essential pieces: why it is a problem in this code, and a fix that would work as written."
  end

  def self.review_context(section:, answer:, rating:)
    [
      "Code Review question: #{section["question"]}",
      "Code snippet: #{section["snippet"]}",
      current_schema_lines(section["current_schema"]),
      answer_lines(answer, rating)
    ].compact.join("\n")
  end

  def self.current_schema_lines(schema)
    return if schema.blank?

    <<~SCHEMA.chomp
      Current schema — the real table(s) as they stand today in db/schema.rb. The snippet is a new migration proposed against them, so a column or index already here is not part of the flaw and the answer does not need to add it:
      #{schema}
    SCHEMA
  end
  private_class_method :current_schema_lines
end
