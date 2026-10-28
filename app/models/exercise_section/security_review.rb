# Restricted to the language's security subset, which is what makes interleaving with code_review deliberate.
class ExerciseSection::SecurityReview < ExerciseSection
  KEY_FIELDS = %w[vulnerability exploit mitigation].freeze

  def self.planted_key? = true

  def self.normalize_planted_key(section) = PlantedKey.fields(section[PlantedKey::FIELD], KEY_FIELDS)

  def self.vocabulary_key
    :security_concepts
  end

  def self.judge_task
    "Identify the one exploitable vulnerability and propose a mitigation."
  end

  def self.discovery?
    true
  end

  def self.code_fields
    %w[snippet]
  end

  def self.generation_guidance(vocabulary:, label:, alongside: [], **)
    <<~GUIDANCE.chomp
      - The "#{key}" section is a SECURITY REVIEW, not a general correctness check. The snippet must contain one real, exploitable vulnerability appropriate to #{label}. The question asks the engineer to identify the vulnerability AND propose a mitigation — not just "what's wrong with this code."
      - Choose the security_review concept from this vocabulary, exactly one — these are the ONLY concepts security_review may use, never one from #{broader_vocabulary_owner(alongside)} broader vocabulary: #{vocabulary.join(", ")}
      - The security_review snippet should be realistic #{label} code, not a contrived toy example#{snippet_bar(alongside)}.
    GUIDANCE
  end

  def self.broader_vocabulary_owner(alongside)
    named = [ ExerciseSection::CodeReview.key, ExerciseSection::Pattern.key ] & alongside
    named.any? ? "#{named.join("/")}'s" : "another section's"
  end
  private_class_method :broader_vocabulary_owner

  def self.snippet_bar(alongside)
    alongside.include?(ExerciseSection::CodeReview.key) ? " — the same bar as #{ExerciseSection::CodeReview.key}'s snippet" : ""
  end
  private_class_method :snippet_bar

  def self.schema_fragment(label:)
    <<~SCHEMA.chomp
      "security_review": {
          "title":        "string",
          "question":     "string — what security vulnerability exists here, and how would you mitigate it",
          "snippet":      "string — #{label} code, ~10-15 lines, containing one real, exploitable vulnerability",
          "scenario": "string — the concrete business-domain framing, e.g. 'inventory restocking service'",
          "teaching_note": "string — 1-2 sentence hint toward HOW to reason, never the answer",
          "concept": "string — exactly one concept from the provided vocabulary",
          "reference": {
            "tagline":      "string — bold one-liner",
            "explanation":  "string — 2-3 sentences",
            "code_example": "string — annotated #{label} code, ~15 lines",
            "senior_lens":  "string — when to reach for it / tradeoffs"
          }
        }
    SCHEMA
  end

  def self.review_context(section:, answer:, rating:)
    <<~CONTEXT.chomp
      Security Review (#{section["title"]}): #{section["question"]}
      Snippet: #{section["snippet"]}
      #{answer_lines(answer, rating)}
    CONTEXT
  end

  def self.grading_note(section:, answer:)
    "Main point: a real, exploitable vulnerability in this code.\n" \
    "Essential pieces: how it would be exploited here, and a mitigation that actually closes it. Judge against " \
    "any sound answer, not one expected wording. Finding the vulnerability without a complete mitigation, or the " \
    "reverse, earns partial credit: name the missing half in \"missed\"."
  end
end
