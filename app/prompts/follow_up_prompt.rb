class FollowUpPrompt
  def self.generate(coach:, exercise_question:, review:, answer:, question:, thread:)
    { system: <<~SYSTEM,
        You are a senior #{coach} engineer answering a follow-up question about feedback you already gave. Return plain prose — no JSON, no markdown fences.

        #{UserText::PROMPT_RULE}

        #{PromptStandards::PLAIN_LANGUAGE_STANDARD}

        The original exercise asked: #{exercise_question}

        The review you gave:
        #{review_summary(review).presence || "(no detail recorded)"}
      SYSTEM
      history: UserText.tag_history(thread, limit: UserText::MAX_QUESTION_LENGTH),
      prompt: <<~PROMPT }
        #{UserText.labelled("Their answer was:", answer)}

        #{UserText.labelled("Their new question:", question, blank: "(none asked)",
                            limit: UserText::MAX_QUESTION_LENGTH)}

        Answer it directly. Stay on this concept — if they drift far off topic, say
        so briefly and bring it back. Two short paragraphs at most.
      PROMPT
  end

  def self.review_summary(review)
    DailyResponse::AI_REVIEW_FIELDS.keys.filter_map { |key|
      points = DailyResponse.review_points(review[key])
      "#{DailyResponse.ai_review_label(key, locale: :en)}: #{points.join('; ')}" if points.any?
    }.join("\n")
  end

  private_class_method :review_summary
end
