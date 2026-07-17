require "faraday"
require "faraday/retry"

class ClaudeService < AiService
  MODEL   = "claude-sonnet-4-5"
  API_URL = "https://api.anthropic.com/v1/messages"

  # 3 total attempts, exponential backoff capped at 8s. `methods: [:post]`
  # is required because faraday-retry's default idempotent-methods list
  # excludes POST, which every call here uses — without it, retries would
  # never fire regardless of retry_statuses. 429 is Anthropic's rate limit;
  # 500/502/503/504 are transient provider-side failures; 529 is Anthropic's
  # own "overloaded" status. Retry-After / RateLimit-Reset response headers
  # are honored automatically by faraday-retry when present, taking
  # precedence over the computed backoff. Exposed as a constant so specs can
  # build an equivalent test connection instead of duplicating these values.
  RETRY_OPTIONS = {
    max:                 2,
    interval:            0.5,
    max_interval:        8,
    backoff_factor:      2,
    interval_randomness: 0.5,
    methods:             [ :post ],
    retry_statuses:      [ 429, 500, 502, 503, 504, 529 ]
  }.freeze

  private

  def call(system:, prompt:)
    body = {
      model:      MODEL,
      max_tokens: 2500,
      system:     system,
      messages:   [ { role: "user", content: prompt } ]
    }

    resp = @conn.post(API_URL, body.to_json)

    unless resp.success?
      log_raw_snippet("Claude API error #{resp.status} body", resp.body)
      message      = extract_provider_message(resp.body, fallback: "Claude API error #{resp.status}")
      error_class  = case resp.status
      when 401, 403 then AiService::AuthenticationError
      when 429, 529 then AiService::RateLimitError # 529 is Anthropic's own "overloaded" status — same transient/retry semantics as 429
      else               AiService::Error
      end
      raise error_class, message
    end

    parsed = JSON.parse(resp.body)
    usage  = parsed["usage"] || {}

    {
      text:          parsed.dig("content", 0, "text"),
      input_tokens:  usage["input_tokens"],
      output_tokens: usage["output_tokens"]
    }
  rescue Faraday::Error => e
    raise AiService::Error, "Network error calling Claude: #{e.message}"
  end

  def build_connection
    Faraday.new do |f|
      f.headers["x-api-key"]         = @api_key
      f.headers["anthropic-version"] = "2023-06-01"
      f.headers["content-type"]      = "application/json"
      f.request :retry, RETRY_OPTIONS
      f.adapter :net_http
    end
  end
end
