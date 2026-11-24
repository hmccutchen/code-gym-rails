class ExplainDifferentlyPrompt
  def self.generate(coach:, question:, answer:, missed:, prior_alternates:, qualitative_feedback: nil)
    heading, points = qualitative_feedback ? [ "Recorded review feedback", qualitative_feedback ] : [ "What they missed", missed ]

    { system: "You are a senior #{coach} engineer re-explaining one point to an engineer who did not follow the first explanation. Return plain prose — no JSON, no markdown fences.\n\n#{UserText::PROMPT_RULE}",
      prompt: <<~PROMPT }
        The engineer was asked: #{question}
        #{UserText.labelled("Their answer:", answer)}

        #{heading}:
        #{points.any? ? points.map { |point| "- #{point}" }.join("\n") : "- (nothing recorded)"}

        #{PromptStandards.prior_framings(prior_alternates)}

        #{PromptStandards.explain_differently_standard("point")}
        Two short paragraphs at most.

        #{PromptStandards::PLAIN_LANGUAGE_STANDARD}
      PROMPT
  end
end
