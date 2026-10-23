class DifficultyPrompt
  GUIDANCE = {
    "straightforward" => "one thing to notice; a competent engineer finds it on a first read.",
    "moderate"        => "a couple of reasoning steps, or one detail that is easy to skim past.",
    "demanding"       => "the issue is subtle, several steps chain together, or the scenario leaves something material unstated."
  }.freeze

  def self.generate(coach:, sections:)
    material = sections.map { |section, data| "## #{section}\n#{SectionContext.render(data)}" }

    { system: "You are a senior #{coach} engineer rating how hard each of several practice problems is. " \
              "You are not grading anyone, and you will not be shown anyone's answer. Return JSON.",
      prompt: <<~PROMPT }
        Rate the objective difficulty of each problem below, on this scale:
        #{scale}

        Judge only the material shown. Weigh how subtle the issue is, how many
        reasoning steps a complete answer takes, and how much the scenario leaves
        unstated. You know nothing about who is answering it, how they have done
        before, or why this problem was chosen for them — none of that is here,
        and none of it belongs in the rating. Two problems about the same idea can
        differ; "#{DailyResponse::DIFFICULTY_LEVELS.first}" is a perfectly good answer.

        Return a single JSON object keyed by the section names below:
        {
          "<section name>": {
            "level": #{DailyResponse::DIFFICULTY_LEVELS.map(&:inspect).join(' | ')},
            "reason": "string — one sentence of at most #{DailyResponse::MAX_DIFFICULTY_REASON_LENGTH} characters naming what makes it that, written for the engineer to read after their review"
          }
        }

        #{material.join("\n\n")}
      PROMPT
  end

  def self.scale
    DailyResponse::DIFFICULTY_LEVELS
      .map { |level| "- \"#{level}\" — #{GUIDANCE.fetch(level)}" }
      .join("\n")
  end

  private_class_method :scale
end
