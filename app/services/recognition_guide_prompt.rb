class RecognitionGuidePrompt
  SCOPE = <<~SCOPE.chomp
    This teaches a PROCESS for recognizing the category, never an ANSWER.
    - Good: "ask whether this interface hides what it should, or makes every caller repeat the same decision."
    - Bad: defining any one concept in the list, such as "shallow_module means the interface is as complex as the implementation". Each concept already has its own reference.
    - Bad: anything that tells the reader what to look for in a particular problem they may be given. Never name or describe a specific planted defect, exercise, or answer.
    It is a lens the reader carries into any problem, not a hint about one.
  SCOPE

  def self.generate(group_key:, subject:)
    concepts = RecognitionGuide.concepts_for(group_key)

    { system: "You are a senior engineer writing a short, durable piece on how to recognize one category of problem. Return ONLY valid JSON.",
      prompt: <<~PROMPT }
        Write a short teaching piece on how to recognize one category of problem.

        The category, "#{group_key.humanize}", is about #{subject}
        The concepts in it are: #{concepts.join(', ')}.
        #{RecognitionGuide.framing_for(group_key)}
        #{tradeoff_line(concepts)}

        #{SCOPE}

        Write for any engineer reading a library, with no exercise in front of them.
        Keep examples language-neutral: plain description, or a few lines of
        pseudocode at most. Invent them; never describe a real exercise.

        This standard applies to every field:
        #{PromptStandards::PLAIN_LANGUAGE_STANDARD}

        Return JSON matching this schema exactly:
        {
          "questions": "string — the questions to ask, in the order you would ask them, when reading code or a plan to see whether it has a problem of this kind. At most two short paragraphs.",
          "contrast":  "string — two short invented situations of the same shape: one where those questions turn something up, and a look-alike where they come back clean. Then say which question told them apart. At most two short paragraphs.",
          "misfires":  "string — how this way of looking goes wrong: what it flags that is not a problem, and what it misses. One short paragraph."
        }
      PROMPT
  end

  def self.tradeoff_line(concepts)
    choices = concepts & ConceptVocabulary::TRADEOFF_CONCEPTS
    return if choices.empty?

    "Some of these (#{choices.join(', ')}) are choices between two defensible options rather than defects. " \
      "For those, the lens recognizes that a choice is being made and which property of the context decides it, never which side is right."
  end

  private_class_method :tradeoff_line
end
