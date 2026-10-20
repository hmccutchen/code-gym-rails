class PseudocodePrompt
  CRITIQUE_SYSTEM = <<~PROMPT.chomp
    You are reviewing an engineer's PSEUDOCODE plan before any code exists. They
    have not submitted or been graded. Your job is to point out genuine gaps in
    the plan's reasoning, and nothing else.

    #{ExerciseSection::PseudocodeToCode.gap_standard}

    Never write code, never show a corrected plan, and never restate their plan
    back to them. Name what breaks and why, in one or two sentences per point.

    If the plan holds up, say so by returning "gaps_found": false with an empty
    "gaps" array. Do NOT invent a point to seem useful — an empty result is a
    valid and expected outcome.

    Return a single JSON object:
    {"gaps_found": true|false, "gaps": ["string", "..."]}
    At most #{ExerciseSection::PseudocodeToCode::MAX_CRITIQUE_POINTS} entries in "gaps".
    "gaps" must be empty when "gaps_found" is false, and non-empty when it is true.
  PROMPT

  TRANSLATE_SYSTEM = <<~PROMPT.chomp
    You translate an engineer's pseudocode into real code. You are a
    TRANSCRIBER, not a reviewer and not an assistant. You do not improve
    anything.

    - If the pseudocode omits an edge case, the code omits it too. Do not add a
      guard, a nil check, a bounds check, or a default the pseudocode did not state.
    - If the pseudocode is ambiguous, pick the MOST LITERAL reading and implement
      that. Do not pick the reading that would work better.
    - If the pseudocode is wrong, implement the wrong thing. Do not fix it.
    - Do not add error handling, logging, validation, or defensive checks.
    - Do not add comments. In particular, never add a comment pointing out a
      problem ("# note: this will fail on empty input"). Naming the flaw is
      someone else's job, not yours.
    - Do not rename, reorder, or restructure for clarity.
    - Add ONLY what is required to make the result syntactically valid:
      declarations, signatures, brackets, imports.

    Return the code and nothing else — no prose, no explanation, no fences.
  PROMPT

  def self.critique(exercise, section, pseudocode)
    { system: "#{CRITIQUE_SYSTEM}\n\n#{UserText::PROMPT_RULE}", prompt: critique_prompt(exercise, section, pseudocode) }
  end

  def self.translate(exercise, section, pseudocode)
    { system: "#{TRANSLATE_SYSTEM}\n\n#{UserText::PROMPT_RULE}", prompt: translate_prompt(exercise, section, pseudocode) }
  end

  def self.critique_prompt(exercise, section, pseudocode)
    data = exercise.problem_set[section.to_s] || {}

    <<~PROMPT
      The problem they are planning:
      #{data["problem_statement"]}

      Their pseudocode:
      #{UserText.tagged(pseudocode)}

      Apply your standard exactly as stated in your system instructions:
      #{ExerciseSection::PseudocodeToCode.gap_standard}
    PROMPT
  end

  def self.translate_prompt(exercise, section, pseudocode)
    data = exercise.problem_set[section.to_s] || {}

    <<~PROMPT
      Target language: #{AiService.config_for(exercise.language)[:label]}.

      The problem they were planning, for naming only — never for filling gaps:
      #{data["problem_statement"]}

      Their pseudocode, to transcribe literally:
      #{UserText.tagged(pseudocode)}
    PROMPT
  end

  private_class_method :critique_prompt, :translate_prompt
end
