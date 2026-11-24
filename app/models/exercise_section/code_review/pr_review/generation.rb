module ExerciseSection::CodeReview::PrReview::Generation
  PrReview = ExerciseSection::CodeReview::PrReview

  CASE_GUIDANCE = {
    "acceptable" => "The change must meet every stated requirement and have no material blocker. Do not manufacture criticism to fill the key.",
    "flawed" => "Give the change exactly one meaningful blocker a reviewer could verify from the shown files and requirements."
  }.freeze

  def self.guidance(vocabulary:, target:)
    <<~PROMPT.chomp
      - Private PR Review target: #{target}. #{CASE_GUIDANCE.fetch(target)}
      - For this Code Review section, the private target governs whether the change has a defect. Other Code Review guidance about finding a defect applies only to a flawed target.
      - Show exactly two related Ruby application excerpts after one bounded change to a service and caller or a model and service. Include the context needed to assess the requirements. An unchanged file may have an empty changed-line list. At least one file must mark a change.
      - Choose the code_review concept from this vocabulary, exactly one: #{vocabulary.join(", ")}
      - Keep the public question neutral for either target. Ask what changed, what the code does across the two files, and what effect it has against the requirements. Ask the reviewer to support approval, an evidence-based nonblocking concern, or a blocker. A concise supported approval can fully answer the prompt.
      - State the intent in one short scenario and give one to three checkable requirements. Give each requirement one concrete condition and outcome. The question, scenario, requirements, and code comments must not label the case, hint at a defect, or disclose a verdict. Do not add a hint, diagram, public finding, or variant marker.
      - Use answer_key for the private target, reason, evidence, and behavior record. For a flawed case, state the blocker and its worked outcome. For an acceptable case, explain why approval is supported. Anchor the reason in one or two exact shown lines, each uniquely identifiable in the named file.
      - In the private behavior record, #{PrReview::BEHAVIOR_GUIDANCE}
    PROMPT
  end

  def self.schema_fragment
    <<~SCHEMA.chomp
      "code_review": {
          "question": "string — the same neutral question for either private target",
          "concept": "string — exactly one concept from the provided vocabulary",
          "scenario": "string — the concrete business-domain framing and intent of the change",
          "requirements": ["string — one to three short and checkable requirements in total"],
          #{(1..PrReview::FILE_RANGE.end).map { |number| file_fields(number) }.join(",\n    ")},
          "answer_key": {
              "case": "string — the private target, acceptable or flawed",
              "reason": "string — a bounded explanation of evidence for approval or a meaningful blocker and its outcome",
              "behavior": { "requirement": 1, "expected": "string — required result", "observed": "string — actual result" },
              "evidence": [{ "path": "string — the exact shown application file path", "quote": "string — one exact visible code line" }]
          }
        }
    SCHEMA
  end

  def self.file_fields(number)
    [
      %("file_#{number}_path": "string — the relative application path for file #{number}"),
      %("file_#{number}_code": "string — the parseable Ruby excerpt after the change, at most #{ExerciseSection::CodeReview::MAX_FILE_LINES} lines"),
      %("file_#{number}_changed": ["string — each changed line in file #{number}, copied exactly"])
    ].join(",\n    ")
  end
  private_class_method :file_fields
end
