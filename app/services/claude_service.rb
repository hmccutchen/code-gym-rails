require "faraday"
require "faraday/retry"
require "json"

class ClaudeService
  class Error < StandardError; end

  API_URL = "https://api.anthropic.com/v1/messages"
  MODEL   = "claude-sonnet-4-5"

  # JSON schema the morning job expects Claude to return for a problem set
  EXERCISE_SCHEMA = <<~SCHEMA
    {
      "code_review": {
        "question": "string — what to find/fix",
        "snippet":  "string — Ruby/Rails code, ~10-15 lines",
        "teaching_note": "string — 1-2 sentence hint toward the key insight, never the answer"
      },
      "pattern": {
        "title":    "string — pattern name",
        "why":      "string — one sentence on why the pattern exists",
        "question": "string — conceptual question to answer",
        "teaching_note": "string — 1-2 sentence hint toward the key insight, never the answer",
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
        "teaching_note": "string — 1-2 sentence hint toward the key insight, never the answer"
      }
    }
  SCHEMA

  def initialize(api_key)
    @api_key = api_key
    @conn    = build_connection
  end

  # ── Generate a personalized daily exercise set ────────────────────────────
  def generate_exercise(user)
    system_prompt = build_system_prompt
    user_prompt   = build_exercise_prompt(user)

    response = call(system: system_prompt, messages: [ { role: "user", content: user_prompt } ])

    # Log usage
    log_usage(user, response, purpose: "generate_exercise")

    # Parse the JSON block out of the response
    parse_json_response(response.dig("content", 0, "text"))
  end

  # ── Review a submitted response inline ───────────────────────────────────
  def review_response(user, exercise, daily_response)
    prompt = build_review_prompt(exercise, daily_response)

    response = call(
      system: "You are a senior Rails engineer giving direct, specific feedback on a junior/mid engineer's Code Gym answers. Be honest and constructive. Return JSON.",
      messages: [ { role: "user", content: prompt } ]
    )

    log_usage(user, response, purpose: "review_response")
    parse_json_response(response.dig("content", 0, "text"))
  end

  private

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
        rating_label = { 0 => "too easy", 1 => "right level", 2 => "too hard" }[h[:rating]] || "unrated"
        feedback     = h[:feedback].present? ? " | Feedback: \"#{h[:feedback]}\"" : ""
        "#{h[:date]}: #{h[:sections_answered]}/3 sections answered | #{rating_label}#{feedback}"
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

  def call(system:, messages:, max_tokens: 2500)
    body = {
      model:      MODEL,
      max_tokens: max_tokens,
      system:     system,
      messages:   messages
    }

    resp = @conn.post(API_URL, body.to_json)

    raise Error, "Claude API error #{resp.status}: #{resp.body}" unless resp.success?

    JSON.parse(resp.body)
  rescue Faraday::Error => e
    raise Error, "Network error calling Claude: #{e.message}"
  end

  def parse_json_response(text)
    # Strip any accidental markdown fences
    clean = text.to_s.gsub(/\A```(?:json)?\n?/, "").gsub(/\n?```\z/, "").strip
    JSON.parse(clean)
  rescue JSON::ParserError => e
    raise Error, "Claude returned invalid JSON: #{e.message}\n\nRaw: #{text}"
  end

  def log_usage(user, response, purpose:)
    usage = response["usage"] || {}
    ApiUsage.create!(
      user:       user,
      tokens_in:  usage["input_tokens"].to_i,
      tokens_out: usage["output_tokens"].to_i,
      purpose:    purpose,
      date:       Date.current
    )
  rescue => e
    Rails.logger.warn("ApiUsage log failed: #{e.message}")
  end

  def build_connection
    Faraday.new do |f|
      f.headers["x-api-key"]         = @api_key
      f.headers["anthropic-version"] = "2023-06-01"
      f.headers["content-type"]      = "application/json"
      f.request :retry, max: 2, interval: 1, retry_statuses: [ 529 ]
      f.adapter :net_http
    end
  end
end
