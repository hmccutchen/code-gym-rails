class ConceptReferencePrompt
  SCOPE = <<~SCOPE.chomp
    This is a stable explanation an engineer returns to across repeat exposure —
    not tied to any single problem.
  SCOPE

  WORKED_EXAMPLE_BOUND = "At most the two fragments plus four sentences of prose.".freeze

  def self.generate(concept:, language:, coach:, label:)
    medium = ConceptVocabulary.language_agnostic?(language) ? nil : label

    { system: "You are a senior #{coach} engineer writing a concise, durable reference for one concept. Return ONLY valid JSON.",
      prompt: <<~PROMPT }
        Write a durable reference for the #{coach} concept: "#{concept}".
        #{SCOPE} Be precise and senior-level.

        Then write a longer, plainer-language guide for someone meeting this
        concept in a library rather than in a problem — no exercise in front of
        them, no answer to reach. Thorough but not an essay: each guide field is
        at most two short paragraphs, except guide_worked_example, which carries
        its own bound below.

        This standard applies to the guide fields and the lesson:
        #{PromptStandards::PLAIN_LANGUAGE_STANDARD}

        Then write a difficulty ladder: for each of #{KindDifficulty::LEVELS.join(', ')}, what a
        problem about THIS concept looks like at that level. Name its concrete form, never a
        description of the level in general. For missing_index, for example: junior is an
        unindexed foreign key, mid_level is an index the query can't use because it wraps the
        column in a function, senior is composite index column order, principal_engineer is
        the write-cost tradeoff of adding an index. Each rung is one or two sentences, under
        #{ConceptReference::MAX_LADDER_RUNG_LENGTH} characters.

        #{lesson_instruction(concept)}

        Return JSON matching this schema exactly:
        {
          "tagline":      "string — bold one-liner",
          "explanation":  "string — 2-3 sentences",
          "code_example": "string — #{code_example_description(medium)}",
          "senior_lens":  "string — #{senior_lens_description(concept)}",
          "guide_plain_language": "string — what this actually is, for a competent engineer who has never met the term",
          "guide_worked_example": "#{worked_example_description(concept, medium)}",
          "guide_pitfalls":       "string — what people get wrong about this, and why the wrong idea is appealing",
        #{ConceptReference::LADDER_FIELD_FOR.map { |level, field| %(  "#{field}": "string — a #{level}-level problem about this concept",) }.join("\n")}
          "lesson": #{JSON.generate(ConceptLesson.schema)}
        }
      PROMPT
  end

  def self.reframe(concept:, coach:, already_read:, prior_alternates:)
    { system: "You are a senior #{coach} engineer re-teaching one concept to an engineer for whom the standard reference did not land. Return plain prose — no JSON, no markdown fences.\n\n#{UserText::PROMPT_RULE}",
      prompt: <<~PROMPT }
        The concept: "#{concept}"

        The reference they have already read:
        #{already_read.map { |field, text| "#{field}: #{text}" }.join("\n")}

        #{PromptStandards.prior_framings(prior_alternates)}

        #{PromptStandards.explain_differently_standard("concept")}
        #{SCOPE} Teach the concept itself; never solve, hint at,
        or refer to any particular exercise. Two short paragraphs at most.

        #{PromptStandards::PLAIN_LANGUAGE_STANDARD}
      PROMPT
  end

  def self.senior_lens_description(concept)
    if ConceptVocabulary::ANTI_SHAPE_CONCEPTS.include?(concept)
      "how to catch it early, what it costs to leave in place, and when the cheaper-looking shape is still worth refusing"
    else
      "when to reach for it / tradeoffs"
    end
  end

  def self.lesson_instruction(concept)
    habits =
      if ConceptVocabulary::TRADEOFF_CONCEPTS.include?(concept)
        "habits: one to #{ConceptLesson::MAX_HABITS} options a team can choose between. Each carries \"catch\": what that option costs."
      else
        "habits: one to #{ConceptLesson::MAX_HABITS} small habits or fixes. Each carries \"catch\": the real limit or cost of that habit, which the reader sees directly after it."
      end

    <<~TEXT.chomp
      Then write a short lesson for someone reading this concept on a phone, under
      "lesson". Every key in it is optional: leave a key out when it does not fit
      this concept, and never pad one to fill it.
      Keep the whole lesson under about #{ConceptLesson::WORD_TARGET} words, in plain prose with no code;
      the code example and the worked example already show the code.
      - definition: one sentence saying what the concept is.
      - comparison: an everyday comparison that maps onto the concept exactly.
      - comparison_limit: one sentence saying where that comparison stops working. Give it with comparison or leave both out; one without the other is dropped.
      - misunderstanding: the most common wrong idea about this concept, and what is true instead.
      - situations: two to #{ConceptLesson::MAX_SITUATIONS} concrete situations where an engineer runs into it, each one short.
      - #{habits}
      - carry_question: one question the reader can ask about their own work.
      - quick_test: a quick way to check their own code or plan for it.
    TEXT
  end

  def self.code_example_description(medium)
    return "illustrative pseudocode or a short language-agnostic snippet, ~15 lines" if medium.nil?

    "annotated #{medium} code, ~15 lines"
  end

  def self.worked_example_description(concept, medium)
    opening = "two short #{medium || 'pseudocode'} fragments of the SAME scenario, " \
              "keeping the same names and shape so the difference reads structurally"

    if ConceptVocabulary::TRADEOFF_CONCEPTS.include?(concept)
      "string — #{opening}: option A, then option B. NEITHER is the corrected version — both are " \
        "legitimate and the choice is context-dependent. Then say in prose what each option buys, what it " \
        "costs, and which property of the context decides between them. #{WORKED_EXAMPLE_BOUND}"
    else
      "string — #{opening}: first the version exhibiting the concept's failure mode, then the " \
        "corrected version of that same scenario. Then say in prose WHY the two relate as a mechanism " \
        "('X causes Y', 'Y is what happens when X breaks down') — never merely that they are " \
        "associated or related. #{WORKED_EXAMPLE_BOUND}"
    end
  end

  private_class_method :senior_lens_description, :lesson_instruction, :code_example_description, :worked_example_description
end
