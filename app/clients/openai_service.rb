require "faraday"
require "faraday/retry"

class OpenaiService < AiService
  API_URL = "https://api.openai.com/v1/responses"

  def self.provider_key = "openai"

  # The legacy branch cannot claim an Anthropic key's "sk-ant-" prefix.
  def self.key_pattern = /\Ask-(proj-|svcacct-|[A-Za-z0-9]{20})/

  DEFAULT_ROUTE = { model: "gpt-6-sol", effort: "none" }.freeze
  MODEL_FOR_PURPOSE = {
    "generate_exercise" => { model: "gpt-6.1-sol", effort: "high" },
    "judge_section"     => { model: "gpt-6-astra", effort: "low", reasoning_allowance: 25_000 }
  }.then { |routes| routes.merge("retry_section" => routes.fetch("generate_exercise")) }.freeze

  REASONING_OFF = {
    "gpt-6-sol"  => "none",
    "gpt-6-luna" => "none"
  }.freeze

  JSON_MODE_REQUEST = "Reply with a JSON object.".freeze

  # `methods: []` routes every retry decision through retry_if; an exhausted-quota 429 is retried too, as statuses match.
  RETRY_OPTIONS = {
    max:                 CallProfiles::RETRY_MAX,
    interval:            0.5,
    max_interval:        CallProfiles::RETRY_MAX_INTERVAL,
    backoff_factor:      2,
    interval_randomness: 0.5,
    methods:             [],
    retry_if:            AiService::RETRY_TIMEOUT_GUARD,
    retry_statuses:      [ 429, 500, 502, 503, 504 ]
  }.freeze

  private

  def provider_name = "OpenAI"

  # A call reasoning within an allowance can spend most of it before timing out, so its timeout is not retried.
  def long_running?(request) = super || route_for(request.purpose).key?(:reasoning_allowance)

  def request_body(request)
    route = route_for(request.purpose)
    body = {
      model:        route[:model],
      instructions: request.system,
      input:        request.history.map { |turn| { role: turn[:role], content: turn[:content] } } +
                    [ { role: "user", content: request.response_schema ? "#{request.prompt}\n\n#{JSON_MODE_REQUEST}" : request.prompt } ],
      store:        false,
      reasoning:    { effort: effort_for(route, capped: request.max_tokens.present?) }
    }
    body[:max_output_tokens] = request.max_tokens + route.fetch(:reasoning_allowance, 0) if request.max_tokens
    # JSON mode, since strict schemas forbid VerdictSchema's root anyOf and optional fields; .parse still holds the shape.
    body[:text] = { format: { type: "json_object" } } if request.response_schema
    body
  end

  INSUFFICIENT_QUOTA = "insufficient_quota".freeze
  RATE_LIMIT_FAMILIES = %w[requests tokens].freeze

  def raise_for_status(resp)
    raise_if_key_rejected("OpenAI", resp.status)
    error = error_envelope(resp.body)
    raise_if_out_of_credit(error, resp.status)

    if resp.status == 429
      raise ProviderError::RateLimitError.new("OpenAI API error 429", http_status: 429,
                                              quota_id: quota_id_from(resp, error), retry_after: retry_after_seconds(resp))
    end

    log_raw_snippet("OpenAI API error #{resp.status} body", resp.body)
    message = extract_provider_message(resp.body, fallback: "OpenAI API error #{resp.status}")
    raise ProviderError.new(message, http_status: resp.status)
  end

  def raise_if_out_of_credit(error, status)
    return unless status == 402 || (status == 429 && error["code"] == INSUFFICIENT_QUOTA)

    Rails.logger.warn("OpenAI reports the account is out of credit (HTTP #{status}, #{error['code']})")
    raise ProviderError::BillingError.new("OpenAI reports the account is out of credit", http_status: status)
  end

  def quota_id_from(resp, error)
    family = RATE_LIMIT_FAMILIES.find { |name| resp.headers["x-ratelimit-remaining-#{name}"].to_s == "0" }
    family ? "x-ratelimit-#{family}" : error["code"].presence || "rate_limit_exceeded"
  end

  def routed_model(purpose) = route_for(purpose)[:model]

  def read_result(parsed, request)
    usage = read_usage(parsed["usage"] || {}, route_for(request.purpose))
    return unfinished_reply(usage, parsed["status"]) unless FINISHED_STATUSES.include?(parsed["status"])

    content = Array(parsed["output"]).select { |item| item["type"] == "message" }.flat_map { |item| Array(item["content"]) }
    usage.merge(
      text:      content.select { |part| part["type"] == "output_text" }.map { |part| part["text"] }.join,
      truncated: parsed["status"] == "incomplete" && !filtered?(parsed),
      refusal:   refusal_category(parsed, content)
    )
  end

  def read_usage(usage, route)
    cached_tokens = usage.dig("input_tokens_details", "cached_tokens").to_i
    cache_write_tokens = usage.dig("input_tokens_details", "cache_write_tokens").to_i

    {
      input_tokens:  usage["input_tokens"].to_i - cached_tokens - cache_write_tokens,
      output_tokens: usage["output_tokens"],
      model:         route[:model],
      cache_read_tokens:  cached_tokens,
      cache_write_tokens: cache_write_tokens
    }
  end

  def route_for(purpose)
    MODEL_FOR_PURPOSE.fetch(purpose, DEFAULT_ROUTE)
  end

  def effort_for(route, capped:)
    if capped && !route.key?(:reasoning_allowance)
      reasoning_off_for(route[:model])
    else
      route[:effort]
    end
  end

  def reasoning_off_for(model)
    REASONING_OFF.fetch(model) { raise ProviderError::UnsupportedRouteError, "#{model} cannot turn reasoning off, so it cannot take a capped call" }
  end

  # A content filter also reports "incomplete", so it is told apart from truncation here.
  def filtered?(parsed)
    parsed.dig("incomplete_details", "reason") == "content_filter"
  end

  def refusal_category(parsed, content)
    return "content_filter" if filtered?(parsed)

    "unspecified" if content.any? { |part| part["type"] == "refusal" }
  end

  def build_connection
    Faraday.new do |f|
      f.options.open_timeout     = CallProfiles::OPEN_TIMEOUT
      f.options.timeout          = CallProfiles::READ_TIMEOUT
      f.headers["authorization"] = "Bearer #{@api_key}"
      f.headers["content-type"]  = "application/json"
      f.request :retry, RETRY_OPTIONS
      f.adapter :net_http
    end
  end
end
