require "faraday"
require "faraday/retry"

class ClaudeService < AiService
  MODEL   = "claude-sonnet-5"
  API_URL = "https://api.anthropic.com/v1/messages"

  # Output ceiling, not a target — Anthropic bills generated tokens, so a
  # headroom-heavy cap costs nothing on the common case. It has to clear the
  # largest response we ask for: a three-section review, each section
  # carrying prose arrays plus a structural `improved_code` block. The
  # original 2500 predated those fields and silently truncated reviews
  # mid-string, which surfaced as a JSON parse error. claude-sonnet-5 thinks
  # by default and max_tokens caps thinking + response text together, so this
  # also has to clear whatever the model spends on unrequested thinking.
  MAX_TOKENS = 16_000

  # 3 total attempts, exponential backoff capped at 8s. `methods: []` forces
  # every retry decision through `retry_if` — faraday-retry treats a method on
  # its `methods` list as retryable outright and never consults `retry_if`, and
  # POST (which every call here uses) has to be on one list or the other or no
  # retry ever fires. 429 is Anthropic's rate limit; 500/502/503/504 are
  # transient provider-side failures; 529 is Anthropic's own "overloaded"
  # status. Retry-After / RateLimit-Reset response headers are honored
  # automatically by faraday-retry when present, taking precedence over the
  # computed backoff. Exposed as a constant so specs can build an equivalent
  # test connection instead of duplicating these values.
  RETRY_OPTIONS = {
    max:                 2,
    interval:            0.5,
    max_interval:        8,
    backoff_factor:      2,
    interval_randomness: 0.5,
    methods:             [],
    retry_if:            AiService::RETRY_TIMEOUT_GUARD,
    retry_statuses:      [ 429, 500, 502, 503, 504, 529 ]
  }.freeze

  private

  def call(system:, prompt:, cache_system: false, read_timeout: READ_TIMEOUT, max_tokens: nil)
    body = {
      model:      MODEL,
      max_tokens: max_tokens || MAX_TOKENS,
      system:     cache_system ? [ { type: "text", text: system, cache_control: { type: "ephemeral" } } ] : system,
      messages:   [ { role: "user", content: prompt } ]
    }
    # A caller-supplied max_tokens is, by construction, tighter than MAX_TOKENS
    # (sized generously specifically to leave room for unrequested thinking —
    # see the comment above). Sharing a tight budget with thinking risks the
    # model spending it all before emitting any reply text, which surfaces as
    # a truncated/empty response and a 503 for an otherwise-valid request.
    # Disabling thinking outright avoids having to guess a split that
    # reserves enough tokens for both.
    body[:thinking] = { type: "disabled" } if max_tokens

    resp = @conn.post(API_URL, body.to_json) do |req|
      req.options.timeout = read_timeout
      req.options.context = (req.options.context || {}).merge(long_running: read_timeout > READ_TIMEOUT)
    end

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
    # claude-sonnet-5 thinks by default (unlike claude-sonnet-4-5), so the
    # text block is no longer reliably content[0] — a leading thinking block
    # pushes it back, and dig(0, "text") silently returns nil.
    text_block = (parsed["content"] || []).find { |block| block["type"] == "text" }

    {
      text:          text_block&.dig("text"),
      input_tokens:  usage["input_tokens"],
      output_tokens: usage["output_tokens"],
      truncated:     parsed["stop_reason"] == "max_tokens"
    }
  rescue Faraday::Error => e
    error_class = e.is_a?(Faraday::TimeoutError) ? AiService::TimeoutError : AiService::Error
    raise error_class, "Network error calling Claude: #{e.message}"
  end

  def build_connection
    Faraday.new do |f|
      f.options.open_timeout         = OPEN_TIMEOUT
      f.options.timeout              = READ_TIMEOUT
      f.headers["x-api-key"]         = @api_key
      f.headers["anthropic-version"] = "2023-06-01"
      f.headers["content-type"]      = "application/json"
      f.request :retry, RETRY_OPTIONS
      f.adapter :net_http
    end
  end
end
