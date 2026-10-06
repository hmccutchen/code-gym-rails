require "faraday"
require "faraday/retry"

class ClaudeService < AiService
  API_URL = "https://api.anthropic.com/v1/messages"

  def self.provider_key = "anthropic"
  def self.key_pattern = /\Ask-ant-/

  # Not yet measured: script/compare_models.rb's review_prose modes measure it,
  # and that has to happen before this switch is turned on.
  def self.judges_review_prose? = true

  # Keyed by the ApiUsage purpose string, so usage rows and routes name calls
  # the same way. script/compare_models.rb is how a candidate route gets read
  # before it is added here. CLAUDE.md's "Per-purpose model routing" holds what
  # to check before moving a purpose — the provider facts behind those checks
  # move, so they live in one place rather than two.
  # Effort is stated even where it is the model's default, so a change to that
  # default cannot move a route silently.
  DEFAULT_ROUTE = { model: "claude-sonnet-5-5", effort: "high" }.freeze
  MODEL_FOR_PURPOSE = {
    "generate_exercise" => { model: "claude-opus-5-5", effort: "medium" },
    "judge_section"     => { model: "claude-sonnet-5-5", effort: "high" },
    "judge_review"      => { model: "claude-sonnet-5-5", effort: "high" }
  }.then { |routes| routes.merge("retry_section" => routes.fetch("generate_exercise")) }.freeze

  # How each model turns thinking off for a capped call. Sonnet 5.5 rejects
  # "disabled" with a 400 and takes "between_tools", which is valid only at
  # effort high or below. Opus 5.5 has no thinking-off setting, so it has no
  # entry and a capped call routed to it raises before sending.
  THINKING_OFF = {
    "claude-sonnet-5-5" => { type: "between_tools" },
    "claude-haiku-4-5"  => { type: "disabled" }
  }.freeze

  # Output ceiling, not a target — Anthropic bills generated tokens, so a
  # headroom-heavy cap costs nothing on the common case. It has to clear the
  # largest response we ask for: a full-day review, each section carrying
  # prose arrays plus a structural `improved_code` block. The original 2500
  # predated those fields and silently truncated reviews mid-string, which
  # surfaced as a JSON parse error. claude-sonnet-5-5 and claude-opus-5-5 both
  # think by default and max_tokens caps thinking + response text together, so
  # this also has to clear whatever the model spends on unrequested thinking.
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
    max:                 AiService::RETRY_MAX,
    interval:            0.5,
    max_interval:        AiService::RETRY_MAX_INTERVAL,
    backoff_factor:      2,
    interval_randomness: 0.5,
    methods:             [],
    retry_if:            AiService::RETRY_TIMEOUT_GUARD,
    retry_statuses:      [ 429, 500, 502, 503, 504, 529 ]
  }.freeze

  private

  def call(system:, prompt:, cache_system: false, read_timeout: READ_TIMEOUT, max_tokens: nil, history: [], purpose: nil, response_schema: nil, single_attempt: false)
    route = route_for(purpose)
    body = {
      model:      route[:model],
      max_tokens: max_tokens || MAX_TOKENS,
      system:     cache_system ? [ { type: "text", text: system, cache_control: { type: "ephemeral" } } ] : system,
      messages:   history.map { |turn| { role: turn[:role], content: turn[:content] } } +
                  [ { role: "user", content: prompt } ]
    }
    # A caller-supplied max_tokens is, by construction, tighter than MAX_TOKENS
    # (sized generously specifically to leave room for unrequested thinking —
    # see the comment above). Sharing a tight budget with thinking risks the
    # model spending it all before emitting any reply text, which surfaces as
    # a truncated/empty response and a 503 for an otherwise-valid request.
    # Turning thinking off avoids having to guess a split that reserves enough
    # tokens for both; THINKING_OFF says how each model does that.
    body[:thinking] = thinking_off_for(route[:model]) if max_tokens
    output_config = { effort: route[:effort], format: json_format(response_schema) }.compact
    body[:output_config] = output_config if output_config.any?

    resp = @conn.post(API_URL, body.to_json) do |req|
      req.options.timeout = read_timeout
      req.options.context = (req.options.context || {}).merge(long_running: read_timeout > READ_TIMEOUT, single_attempt: single_attempt)
    end

    unless resp.success?
      raise_if_key_rejected("Anthropic", resp.status)

      log_raw_snippet("Claude API error #{resp.status} body", resp.body)
      message      = extract_provider_message(resp.body, fallback: "Claude API error #{resp.status}")
      error_class  = case resp.status
      when 429, 529 then AiService::RateLimitError # 529 is Anthropic's own "overloaded" status — same transient/retry semantics as 429
      else               AiService::Error
      end
      raise error_class.new(message, http_status: resp.status)
    end

    parsed = parse_provider_envelope(resp.body, provider: "Claude")
    usage  = parsed["usage"] || {}
    # Current Sonnet models think by default (unlike claude-sonnet-4-5), so the
    # text block is no longer reliably content[0] — a leading thinking block
    # pushes it back, and dig(0, "text") silently returns nil.
    text_block = (parsed["content"] || []).find { |block| block["type"] == "text" }

    {
      text:          text_block&.dig("text"),
      input_tokens:  usage["input_tokens"],
      output_tokens: usage["output_tokens"],
      model:         route[:model],
      # input_tokens excludes both, and each is billed at its own rate.
      cache_read_tokens:  usage["cache_read_input_tokens"].to_i,
      cache_write_tokens: usage["cache_creation_input_tokens"].to_i,
      truncated:     parsed["stop_reason"] == "max_tokens",
      # Reported as data, like truncation, so call_and_log records the billed
      # usage before it raises: a refused request still charges its input.
      refusal:       refusal_category(parsed)
    }
  rescue Faraday::Error => e
    error_class = e.is_a?(Faraday::TimeoutError) ? AiService::TimeoutError : AiService::Error
    raise error_class, "Network error calling Claude: #{e.message}"
  end

  # Structured outputs rather than a prefilled "{": every model this service
  # routes to rejects an assistant prefill with a 400.
  def json_format(schema)
    { type: "json_schema", schema: schema } if schema
  end

  def route_for(purpose)
    MODEL_FOR_PURPOSE.fetch(purpose, DEFAULT_ROUTE)
  end

  def thinking_off_for(model)
    THINKING_OFF.fetch(model) { raise AiService::UnsupportedRouteError, "#{model} has no thinking-off setting, so it cannot take a capped call" }
  end

  def refusal_category(parsed)
    return nil unless parsed["stop_reason"] == "refusal"

    parsed.dig("stop_details", "category") || "unspecified"
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
