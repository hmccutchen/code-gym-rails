class ReviewPrompt
  # A change to what a rating means must decide whether to raise ReviewedSectionResults::RUBRIC_VERSION, which restarts the evidence it stamps.
  RATING_RUBRIC = <<~RUBRIC.chomp.freeze
    How to choose "rating": rate the answer against the level its section was pitched at, which the grading instruction states on its "Pitched at" line, so a rating means the same thing at every level. Base it on the gaps you list in "missed". A gap is essential when, left as the engineer wrote it, the code or decision would behave wrongly or a requirement the problem states would go unmet. Missing syntax, polish or wording, or a step any engineer at this level would take for granted, is not essential and does not lower the rating. Judge what is essential against the problem as written: a problem simpler than its level's description is graded on what it actually asks. Each section's grading note says what its main point and its essential pieces are.
    - "beginner": missed the main point of the section.
    - "developing": found the main point, but missed or misexplained at least one essential piece.
    - "solid": no essential misses.
    - "strong": solid, plus something the question did not ask for that matters here, such as a tradeoff or a consequence.
    The rating must agree with "missed": when "missed" names an essential gap, the rating is not "solid" or "strong". When a section's grading note says its rating is already fixed, that note wins.
  RUBRIC

  ENTRY_RULES = <<~RULES.chomp.freeze
    Each array entry must be ONE self-contained idea in one or two sentences. Never pack
    several points into one entry, and never number points inside an entry ("1) ... 2) ...")
    — separate ideas belong in separate entries. Use an empty array when there is nothing to
    say for that field.
  RULES

  def self.day_system(coach:, sections:)
    others = sections.size - 1
    others_clause =
      case others
      when 0 then "no other sections today"
      when 1 then "the other section is"
      else "the other #{others} sections are"
      end
    contexts = sections.map do |entry|
      ExerciseSection.for(entry[:key]).review_context(section: entry[:section], answer: entry[:answer], rating: entry[:rating])
    end

    <<~CONTEXT
      You are a senior #{coach} engineer giving direct, specific feedback on an engineer's Code Gym answers. You will grade exactly one of the day's #{sections.size} sections in a follow-up instruction — #{others_clause} given here only as context, since each section is rated against its own pitched level. Be honest and constructive. Return JSON.

      #{UserText::PROMPT_RULE}

      #{RATING_RUBRIC}

      #{PromptStandards::PLAIN_LANGUAGE_STANDARD}

      #{contexts.join("\n\n")}
    CONTEXT
  end

  def self.section_prompt(key:, section:, answer:, rung:)
    kind = ExerciseSection.for(key)

    <<~PROMPT
      Grade ONLY the "#{key}" section from the day's context above.
      Pitched at: #{rung} — #{KindDifficulty::LEVEL_DEFINITIONS.fetch(rung)}

      #{kind.grading_note(section: section, answer: answer)}

      #{json_header(key)}
      - "rating": "beginner" | "developing" | "solid" | "strong"
      - "correct": array of strings — each entry one distinct thing they got right
      - "missed": array of strings — each entry one distinct thing they missed or got wrong
      - "essential_gaps": array of integers — the zero-based positions in "missed" of the entries that are essential gaps; an empty array when none are
      #{shared_review_fields(kind)}

      #{ENTRY_RULES}
    PROMPT
  end

  def self.walkthrough_prompt(key:, section:, rung:, written:)
    kind = ExerciseSection.for(key)

    <<~PROMPT
      Walk through the "#{key}" section from the day's context above. #{walkthrough_opening(written)}
      Pitched at: #{rung} — #{KindDifficulty::LEVEL_DEFINITIONS.fetch(rung)}

      #{json_header(key)}
      - "correct": array of strings — each entry one distinct thing in what they wrote that is on the right track
      - "missed": array of strings — each entry one distinct thing a good answer would cover
      #{shared_review_fields(kind)}

      #{ENTRY_RULES}
    PROMPT
  end

  def self.walkthrough_opening(written)
    return 'No answer was given for this section, so it must not be rated. Return "correct" as an empty array, since nothing was written.' if written.nil?

    <<~OPENING.chomp
      The engineer wrote only the text below, which is too short to count as an answer, so it must not be rated.
      The day's context shows no answer for this section because what they wrote was too short to count; here is what they wrote.
      #{UserText.labelled("What they wrote:", written)}
      Put what in it is on the right track, if anything, in "correct" first, then walk through what a good answer covers.
    OPENING
  end

  def self.json_header(key)
    %(Return a single JSON object (NOT wrapped in a "#{key}" key) with:)
  end

  def self.shared_review_fields(kind)
    <<~FIELDS.chomp
      - "better_questions": array of strings — each entry one question they should have asked themselves
      - "next_step": string — one specific thing to study
      - "improved_code": string — #{improved_code_instruction(kind)}
    FIELDS
  end

  def self.improved_code_instruction(kind)
    kind.improved_code? ?
      "the #{kind.improved_code_label.downcase} for this section" :
      "must be an empty string for this section"
  end

  private_class_method :improved_code_instruction, :walkthrough_opening, :json_header, :shared_review_fields
end
