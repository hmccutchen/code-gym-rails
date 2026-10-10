require "faraday"
require "faraday/retry"

class ClaudeService < AiService
  API_URL = "https://api.anthropic.com/v1/messages"

  def self.provider_key = "anthropic"
  def self.key_pattern = /\Ask-ant-/

  # Still gated by REVIEW_PROSE_JUDGE; see CLAUDE.md, "Review prose judge".
  def self.judges_review_prose? = true

  # Keyed by ApiUsage purpose; effort is stated even at the default. See CLAUDE.md, "Per-purpose model routing".
  DEFAULT_ROUTE = { model: "claude-sonnet-5-5", effort: "high" }.freeze
  MODEL_FOR_PURPOSE = {
    "generate_exercise" => { model: "claude-opus-5-5", effort: "medium" },
    "judge_section"     => { model: "claude-sonnet-5-5", effort: "high" },
    "judge_review"      => { model: "claude-sonnet-5-5", effort: "high" }
  }.then { |routes| routes.merge("retry_section" => routes.fetch("generate_exercise")) }.freeze

  # Sonnet 5.5 rejects "disabled" with a 400; Opus 5.5 has no off setting, so a capped call routed to it raises.
  THINKING_OFF = {
    "claude-sonnet-5-5" => { type: "between_tools" },
    "claude-haiku-4-5"  => { type: "disabled" }
  }.freeze

  # Must clear a full-day review plus default thinking, which max_tokens caps too; 2500 once truncated reviews mid-string.
  MAX_TOKENS = 16_000

  # `methods: []` routes every retry decision through retry_if; a listed method is retried without consulting it.
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
    # A tight caller cap shared with thinking can be spent before any reply text, so thinking goes off.
    body[:thinking] = thinking_off_for(route[:model]) if max_tokens
    output_config = { effort: route[:effort], format: json_format(response_schema) }.compact
    body[:output_config] = output_config if output_config.any?

    resp = @conn.post(API_URL, body.to_json) do |req|
      req.options.timeout = read_timeout
      req.options.context = (req.options.context || {}).merge(long_running: read_timeout > READ_TIMEOUT, single_attempt: single_attempt)
    end

    raise_for_status(resp) unless resp.success?

    parsed = parse_provider_envelope(resp.body, provider: "Claude")
    usage  = parsed["usage"] || {}
    # A leading thinking block means the text block is not reliably content[0].
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
      # Reported as data so call_and_log records usage first: a refused request still charges its input.
      refusal:       refusal_category(parsed),
      http_status:   resp.status
    }
  rescue Faraday::Error => e
    error_class = e.is_a?(Faraday::TimeoutError) ? AiService::TimeoutError : AiService::NetworkError
    raise error_class, "Network error calling Claude: #{e.message}"
  end

  # Out-of-credit replies (402, 400 spend-limit message, 429 enforced_spend_limit_reached) are never retried as rate limits.
  SPEND_LIMIT_MESSAGE = /\A(You have reached your specified|Your credit balance)/
  ENFORCED_SPEND_LIMIT = "enforced_spend_limit_reached".freeze

  # The first rate-limit header family whose remaining count reads zero names the limit a 429 hit.
  RATE_LIMIT_FAMILIES = %w[requests input-tokens output-tokens tokens].freeze

  def raise_for_status(resp)
    raise_if_key_rejected("Anthropic", resp.status)
    error = error_envelope(resp.body)
    raise_if_out_of_credit(error, resp.status)

    case resp.status
    when 429
      raise AiService::RateLimitError.new("Claude API error 429", http_status: 429,
                                          quota_id: quota_id_from(resp, error), retry_after: retry_after_seconds(resp))
    when 529
      raise AiService::RateLimitError.new("Claude API error 529", http_status: 529, quota_id: "overloaded_error")
    end

    log_raw_snippet("Claude API error #{resp.status} body", resp.body)
    message = extract_provider_message(resp.body, fallback: "Claude API error #{resp.status}")
    raise AiService::Error.new(message, http_status: resp.status)
  end

  def raise_if_out_of_credit(error, status)
    out_of_credit = status == 402 ||
                    (status == 400 && error["message"].to_s.match?(SPEND_LIMIT_MESSAGE)) ||
                    (status == 429 && error.dig("details", "error_code") == ENFORCED_SPEND_LIMIT)
    return unless out_of_credit

    Rails.logger.warn("Anthropic reports the account is out of credit or over its spend limit (HTTP #{status})")
    raise AiService::BillingError.new("Anthropic reports the account is out of credit or over its spend limit",
                                      http_status: status)
  end

  def quota_id_from(resp, error)
    family = RATE_LIMIT_FAMILIES.find { |name| resp.headers["anthropic-ratelimit-#{name}-remaining"].to_s == "0" }
    family ? "anthropic-ratelimit-#{family}" : error["type"].presence || "rate_limit_error"
  end

  def routed_model(purpose) = route_for(purpose)[:model]

  # Structured outputs rather than a prefilled "{": every model routed here rejects an assistant prefill with a 400.
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
