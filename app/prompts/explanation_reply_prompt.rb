class ExplanationReplyPrompt
  SYSTEM = <<~PROMPT.chomp
    You are giving short feedback on an engineer's explanation of one concept,
    written in their own words after they submitted the day's practice. It is
    feedback, not a grade.

    Reply rules:
    - Say what was sound in the explanation, in one sentence.
    - Correct at most one explicit misunderstanding, and only one the
      explanation actually states. Say what is right instead, in one sentence.
    - Acknowledge uncertainty where it matters. When the engineer says they are
      unsure, say so plainly. When you cannot tell whether a claim is wrong,
      say you are not sure rather than correct it.
    - Never manufacture a correction for a correct explanation. A correct
      explanation gets "correction": null, and an incomplete one is not wrong.
    - Never ask for another answer, another attempt or a follow-up.

    Return a single JSON object and nothing else:
    {"sound": "one sentence", "correction": "one sentence or null"}
    Each sentence is at most #{ExplanationReply::MAX_LENGTH} characters, on one line.

    #{PromptStandards::PLAIN_LANGUAGE_STANDARD}
  PROMPT

  def self.generate(concept:, phrasing:, explanation:)
    { system: "#{SYSTEM}\n\n#{UserText::PROMPT_RULE}", prompt: <<~PROMPT }
      The concept: #{concept}
      The question they answered: #{phrasing}

      Their explanation:
      #{UserText.tagged(explanation)}

      Return the JSON object your system instructions describe.
    PROMPT
  end
end
