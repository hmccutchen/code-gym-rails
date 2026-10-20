class ReviewProseJudgePrompt
  ISSUE_GUIDANCE = {
    "plain_language_violation" => "jargon or buzzwords where a plainer word works, filler such as \"basically\" or \"at the end of the day\", or a miss explained in a more complicated way than it needs.",
    "verbosity" => "the same point made twice, the rating restated in prose, or filler."
  }.freeze

  ISSUE_LINES = ReviewProseVerdict::ISSUE_TYPES
    .map { |type| "- #{type}: #{ISSUE_GUIDANCE.fetch(type)}" }
    .join("\n").freeze

  SYSTEM = <<~PROMPT.freeze
    You are editing the prose of one section's code review so the engineer who submitted the work can read it easily. The grade is final: you change how the review says things, never what it says.

    Check for these problems, the only #{ReviewProseVerdict::ISSUE_TYPES.size}:
    #{ISSUE_LINES}

    #{PromptStandards::PLAIN_LANGUAGE_STANDARD}

    Rules for any rewrite:
    - Keep what every entry claims. Keep each negation ("does not", "never"), each condition ("only when", "unless"), and every identifier (a method, column, constant or file name) exactly as written.
    - Never add a claim, a fix or an example the entry does not already make. Never touch code.
    - Keep how sure each claim is. A word that limits a claim ("may", "often", "in some cases") stays, and a vague claim stays vague: "this could get slow with lots of rows" can become "this may get slow with lots of rows", never "this times out with lots of rows".
    - Keep every topic a next step names. Shorten how it says them; never choose some and drop the rest.
    - A list field is rewritten as entries, each with "from": the zero-based indexes of the original entries it replaces. Cite every original index exactly once. Merge entries only when they make the same point, and then report a verbosity issue. Order entries by their first index.
    - Rewrite only the fields that have a problem and leave the others out. If nothing needs changing, return keep.
    - Each issue's evidence quotes the text it is about.

    Work through this internally, then reply with only the JSON verdict, with no text before or after it.
  PROMPT

  def self.generate(kind:, coach:, projection:)
    { response_schema: ReviewProseVerdict.schema, system: SYSTEM, prompt: <<~PROMPT }
      Section kind: #{kind.key}
      The review is written for an engineer working in #{coach}.
      Each list field is an array; an entry's index is its zero-based position.

      The review's prose:
      #{JSON.pretty_generate(projection)}
    PROMPT
  end
end
