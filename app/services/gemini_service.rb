require "faraday"
require "faraday/retry"

class GeminiService < AiService
  MODEL   = "gemini-3.5-flash"
  API_URL = "https://generativelanguage.googleapis.com/v1beta/interactions"

  # 3 total attempts, exponential backoff capped at 8s. `methods: [:post]`
  # is required because faraday-retry's default idempotent-methods list
  # excludes POST, which every call here uses — without it, retries would
  # never fire regardless of retry_statuses. 429 matters most here: the
  # Gemini free tier's ~15 req/min limit means teammates generating around
  # the same time can collide. Retry-After / RateLimit-Reset response
  # headers are honored automatically by faraday-retry when present, taking
  # precedence over the computed backoff. Exposed as a constant so specs can
  # build an equivalent test connection instead of duplicating these values.
  RETRY_OPTIONS = {
    max:                 2,
    interval:            0.5,
    max_interval:        8,
    backoff_factor:      2,
    interval_randomness: 0.5,
    methods:             [ :post ],
    retry_statuses:      [ 429, 500, 502, 503, 504 ]
  }.freeze

  private

  def call(system:, prompt:)
    body = {
      model:              MODEL,
      system_instruction: system,
      input:              prompt,
      store:              false
    }

    resp = @conn.post(API_URL, body.to_json)

    unless resp.success?
      log_raw_snippet("Gemini API error #{resp.status} body", resp.body)
      message      = extract_provider_message(resp.body, fallback: "Gemini API error #{resp.status}")
      error_class  = case resp.status
      when 401, 403 then AiService::AuthenticationError
      when 429      then AiService::RateLimitError
      else               AiService::Error
      end
      raise error_class, message
    end

    parsed       = JSON.parse(resp.body)
    model_output = Array(parsed["steps"]).find { |s| s["type"] == "model_output" }
    text_parts   = Array(model_output && model_output["content"]).select { |c| c["type"] == "text" }.map { |c| c["text"] }
    usage        = parsed["usage"] || {}

    {
      text:          text_parts.join,
      input_tokens:  usage["total_input_tokens"],
      output_tokens: usage["total_output_tokens"]
    }
  rescue Faraday::Error => e
    raise AiService::Error, "Network error calling Gemini: #{e.message}"
  end

  def build_connection
    Faraday.new do |f|
      f.headers["x-goog-api-key"] = @api_key
      f.headers["content-type"]   = "application/json"
      f.request :retry, RETRY_OPTIONS
      f.adapter :net_http
    end
  end
end
