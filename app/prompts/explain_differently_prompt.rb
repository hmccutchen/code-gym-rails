class ExplainDifferentlyPrompt
  def self.generate(coach:, question:, answer:, missed:, prior_alternates:)
    { system: "You are a senior #{coach} engineer re-explaining one point to an engineer who did not follow the first explanation. Return plain prose — no JSON, no markdown fences.\n\n#{UserText::PROMPT_RULE}",
      prompt: <<~PROMPT }
        The engineer was asked: #{question}
        #{UserText.labelled("Their answer:", answer)}

        What they missed:
        #{missed.any? ? missed.map { |m| "- #{m}" }.join("\n") : "- (nothing recorded)"}

        #{PromptStandards.prior_framings(prior_alternates)}

        #{PromptStandards.explain_differently_standard("point")}
        Two short paragraphs at most.

        #{PromptStandards::PLAIN_LANGUAGE_STANDARD}
      PROMPT
  end
end
