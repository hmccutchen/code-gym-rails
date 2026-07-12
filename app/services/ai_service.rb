require "json"

class AiService
  class Error < StandardError; end

  # Fixed concept vocabulary. Embedded in the generation prompt; anything a
  # provider returns outside this list is normalized to "other" so per-user
  # concept history stays aggregatable.
  CONCEPTS = %w[
    n_plus_one transaction_safety memoization service_objects scope_chaining
    idempotency authorization background_jobs caching validations
    callbacks_vs_service query_objects policy_objects indexing concurrency
    error_handling
  ].freeze

  RATING_LABELS = { "too_easy" => "too easy", "right_level" => "right level", "too_hard" => "too hard" }.freeze

  # Max bytes of raw provider output logged server-side when a provider
  # response can't be used (invalid JSON, non-success HTTP status). Keeps
  # exception messages — which surface in flash alerts and error trackers —
  # free of large/undesired provider content.
  RAW_SNIPPET_LIMIT = 500

  # JSON schema every provider is asked to return for a problem set
  EXERCISE_SCHEMA = <<~SCHEMA
    {
      "code_review": {
        "question": "string — what to find/fix",
        "snippet":  "string — Ruby/Rails code, ~10-15 lines",
        "teaching_note": "string — 1-2 sentence hint toward the key insight, never the answer",
        "concept": "string — exactly one concept from the provided vocabulary"
      },
      "pattern": {
        "title":    "string — pattern name",
        "why":      "string — one sentence on why the pattern exists",
        "question": "string — conceptual question to answer",
        "teaching_note": "string — 1-2 sentence hint toward the key insight, never the answer",
        "concept": "string — exactly one concept from the provided vocabulary",
        "reference": {
          "tagline":      "string — bold one-liner",
          "explanation":  "string — 2-3 sentences",
          "code_example": "string — annotated Ruby, ~15 lines",
          "senior_lens":  "string — when to reach for it / tradeoffs"
        }
      },
      "challenge": {
        "title":        "string",
        "question":     "string — what to implement",
        "starter_code": "string — optional skeleton (empty string if none)",
        "teaching_note": "string — 1-2 sentence hint toward the key insight, never the answer",
        "concept": "string — exactly one concept from the provided vocabulary"
      }
    }
  SCHEMA

  def initialize(api_key)
    @api_key = api_key
    @conn    = build_connection
  end

  # ── Dispatch to the right provider for this user ─────────────────────────
  def self.for(user)
    case user.provider
    when "anthropic" then ClaudeService.new(user.api_key)
    when "gemini"    then GeminiService.new(user.api_key)
    else
      raise Error, "User #{user.id} has no recognized AI provider configured"
    end
  end

  # ── Generate a personalized daily exercise set ────────────────────────────
  def generate_exercise(user)
    result = call(system: build_system_prompt, prompt: build_exercise_prompt(user))

    log_usage(user, result, purpose: "generate_exercise")
    normalize_concepts(parse_json_response(result[:text]))
  end

  # ── Review a submitted response inline ───────────────────────────────────
  def review_response(user, exercise, daily_response)
    result = call(
      system: "You are a senior Rails engineer giving direct, specific feedback on a junior/mid engineer's Code Gym answers. Be honest and constructive. Return JSON.",
      prompt: build_review_prompt(exercise, daily_response)
    )

    log_usage(user, result, purpose: "review_response")
    parse_json_response(result[:text])
  end

  private

  # Subclasses must implement: makes the provider-specific HTTP call and
  # returns a normalized Hash { text:, input_tokens:, output_tokens: }.
  def call(system:, prompt:)
    raise NotImplementedError, "#{self.class} must implement #call"
  end

  # Subclasses must implement: returns a configured Faraday::Connection.
  def build_connection
    raise NotImplementedError, "#{self.class} must implement #build_connection"
  end

  def build_system_prompt
    <<~PROMPT
      You are a senior Rails engineering coach generating personalized daily exercise sets.
      Your goal is to push engineers toward senior-level thinking: not just "what" but "why" and "when not to."
      Focus on real Rails patterns: N+1 queries, idempotency, background jobs, authorization, service objects, query objects, policy objects.
      Return ONLY valid JSON — no markdown fences, no explanation outside the JSON.
    PROMPT
  end

  def build_exercise_prompt(user)
    history = user.recent_performance(days: 10)

    history_text = if history.empty?
      "No history yet — this is their first exercise set."
    else
      history.map { |h|
        rating_label = RATING_LABELS[h[:rating]] || "unrated"
        feedback     = h[:feedback].present? ? " | Feedback: \"#{h[:feedback]}\"" : ""
        concepts     = h[:concepts].respond_to?(:values) ? h[:concepts].values.compact.uniq : []
        concept_text = concepts.any? ? " | concepts: #{concepts.join(', ')}" : ""
        "#{h[:date]}: #{h[:sections_answered]}/3 sections answered | #{rating_label}#{concept_text}#{feedback}"
      }.join("\n")
    end

    focus = user.focus_areas.any? ? user.focus_areas.join(", ") : "general Rails patterns"

    <<~PROMPT
      Generate a daily Code Gym exercise set for this engineer.

      Engineer profile:
      - Name: #{user.name}
      - Skill level: #{user.skill_level} (beginner → developing → solid → strong)
      - Priority focus areas: #{focus}

      Recent performance (last 10 sessions):
      #{history_text}

      Instructions:
      - If they've been rating exercises "too easy", increase difficulty and reduce explanation in the reference.
      - If they've been rating "too hard" or skipping sections, simplify and add more scaffolding.
      - Prioritize focus areas they've missed or rated hard recently.
      - The code_review snippet must be realistic Rails code — not toy examples.
      - The challenge starter_code should give enough scaffold to get started without giving away the answer.
      - Rotate between topics across sessions — avoid the same pattern two days in a row.
      - Each teaching_note must point toward how to think about the problem or the right question to ask — one or two sentences, never the full answer.
      - Choose each section's concept from this fixed vocabulary, exactly one per section: #{CONCEPTS.join(", ")}
      - Mastery loop: for any concept whose most recent rating was "too hard", reintroduce that concept in this set with a different code example and framing — same underlying concept, never a repeat of the same snippet. Keep reintroducing it in every subsequent set until the user rates a set containing it "right level" or "too easy"; that rating is the mastery signal that ends reinforcement for that concept.
      - Concepts most recently rated "too easy" must not repeat within the same week.
      - Concepts most recently rated "right level" have no special weighting.

      Return JSON matching this schema exactly:
      #{EXERCISE_SCHEMA}
    PROMPT
  end

  def build_review_prompt(exercise, daily_response)
    answers = daily_response.answers

    <<~PROMPT
      Review these Code Gym answers. For each section, return a JSON object with:
      - "rating": "beginner" | "developing" | "solid" | "strong"
      - "correct": string — what they got right
      - "missed": string — what they missed or got wrong
      - "better_questions": string — questions they should have asked themselves
      - "next_step": string — one specific thing to study
      - "improved_code": string — corrected/improved code (for code sections only; empty string otherwise)

      Exercise:
      Code Review question: #{exercise.code_review["question"]}
      Code snippet: #{exercise.code_review["snippet"]}
      Their answer: #{answers["code_review"].presence || "(skipped)"}

      Pattern question (#{exercise.pattern["title"]}): #{exercise.pattern["question"]}
      Their answer: #{answers["pattern"].presence || "(skipped)"}

      Coding Challenge: #{exercise.challenge["question"]}
      Their answer: #{answers["challenge"].presence || "(skipped)"}

      Return JSON with keys: "code_review", "pattern", "challenge" — each matching the schema above.
    PROMPT
  end

  def parse_json_response(text)
    # Strip any accidental markdown fences
    clean = text.to_s.gsub(/\A```(?:json)?\n?/, "").gsub(/\n?```\z/, "").strip
    JSON.parse(clean)
  rescue JSON::ParserError => e
    log_raw_snippet("Invalid JSON from provider", text)
    raise Error, "Provider returned invalid JSON: #{e.message}"
  end

  # Logs a truncated snippet of raw provider output server-side instead of
  # embedding it in an exception message — exception messages surface in
  # flash alerts and error trackers, where large/undesired content would
  # leak to users and bloat logs.
  def log_raw_snippet(label, content)
    text = content.to_s
    snippet = text.byteslice(0, RAW_SNIPPET_LIMIT)
    snippet += "... (truncated, #{text.bytesize} bytes total)" if text.bytesize > RAW_SNIPPET_LIMIT
    Rails.logger.error("#{label}: #{snippet}")
  end

  # A provider occasionally invents tags; keep the vocabulary closed so
  # aggregation over concept history stays clean.
  def normalize_concepts(problem_set)
    unless problem_set.is_a?(Hash)
      raise Error, "Provider returned #{problem_set.class} instead of a JSON object for the problem set"
    end

    problem_set.each_value do |section|
      next unless section.is_a?(Hash) && section.key?("concept")
      section["concept"] = "other" unless CONCEPTS.include?(section["concept"])
    end
    problem_set
  end

  def log_usage(user, result, purpose:)
    ApiUsage.create!(
      user:       user,
      tokens_in:  result[:input_tokens].to_i,
      tokens_out: result[:output_tokens].to_i,
      purpose:    purpose,
      date:       Date.current
    )
  rescue => e
    Rails.logger.warn("ApiUsage log failed: #{e.message}")
  end
end
