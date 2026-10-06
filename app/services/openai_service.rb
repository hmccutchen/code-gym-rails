require "faraday"
require "faraday/retry"

class OpenaiService < AiService
  API_URL = "https://api.openai.com/v1/responses"

  def self.provider_key = "openai"

  # The legacy branch cannot claim an Anthropic key's "sk-ant-" prefix.
  def self.key_pattern = /\Ask-(proj-|svcacct-|[A-Za-z0-9]{20})/

  # Keyed by the ApiUsage purpose string, like ClaudeService's. No route has
  # been compared against another model yet. Effort is stated even where it is
  # the model's default, so a change to that default cannot move a route
  # silently. Generation is never capped, so it can take 6.1 Sol, which cannot
  # turn reasoning off. The judge is capped, and Astra cannot turn reasoning
  # off either, so its route carries a reasoning allowance (see
  # #request_body). Everything else runs on 6 Sol with reasoning off.
  DEFAULT_ROUTE = { model: "gpt-6-sol", effort: "none" }.freeze
  MODEL_FOR_PURPOSE = {
    "generate_exercise" => { model: "gpt-6.1-sol", effort: "high" },
    # 25,000 is OpenAI's suggested starting reserve for reasoning and output.
    # Low is Astra's lowest effort, chosen because the judge's read timeout is
    # 45 seconds.
    "judge_section"     => { model: "gpt-6-astra", effort: "low", reasoning_allowance: 25_000 }
  }.then { |routes| routes.merge("retry_section" => routes.fetch("generate_exercise")) }.freeze

  # max_output_tokens caps reasoning and reply together, so a capped call turns
  # reasoning off or the model can spend the cap before it answers. 6.1 Sol and
  # Astra have no "none" effort, so they have no entry, and a capped call routed
  # to either raises before sending unless its route carries a
  # reasoning_allowance.
  REASONING_OFF = {
    "gpt-6-sol"  => "none",
    "gpt-6-luna" => "none"
  }.freeze

  # OpenAI refuses JSON mode with a 400 unless an input message mentions JSON,
  # and the system prompt goes in instructions, which it does not count (#253).
  JSON_MODE_REQUEST = "Reply with a JSON object.".freeze

  # 3 total attempts, exponential backoff capped at 8s. `methods: []` forces
  # every retry decision through `retry_if` — faraday-retry treats a method on
  # its `methods` list as retryable outright and never consults `retry_if`, and
  # POST (which every call here uses) has to be on one list or the other or no
  # retry ever fires. A 429 for an exhausted quota is retried too, since its
  # status does not say which kind it is; that costs two wasted attempts.
  RETRY_OPTIONS = {
    max:                 AiService::RETRY_MAX,
    interval:            0.5,
    max_interval:        AiService::RETRY_MAX_INTERVAL,
    backoff_factor:      2,
    interval_randomness: 0.5,
    methods:             [],
    retry_if:            AiService::RETRY_TIMEOUT_GUARD,
    retry_statuses:      [ 429, 500, 502, 503, 504 ]
  }.freeze

  private

  def call(system:, prompt:, cache_system: false, read_timeout: READ_TIMEOUT, max_tokens: nil, history: [], purpose: nil, response_schema: nil, single_attempt: false)
    route = route_for(purpose)
    body  = request_body(route, system: system, prompt: prompt, history: history, max_tokens: max_tokens, response_schema: response_schema)

    # A call that reasons within an allowance can spend most of the allowance
    # before it times out, so its timeout is final rather than retried.
    final_timeout = read_timeout > READ_TIMEOUT || route.key?(:reasoning_allowance)
    resp = @conn.post(API_URL, body.to_json) do |req|
      req.options.timeout = read_timeout
      req.options.context = (req.options.context || {}).merge(long_running: final_timeout, single_attempt: single_attempt)
    end
    raise_for_status(resp) unless resp.success?

    read_result(parse_provider_envelope(resp.body, provider: "OpenAI"), route).merge(http_status: resp.status)
  rescue Faraday::Error => e
    error_class = e.is_a?(Faraday::TimeoutError) ? AiService::TimeoutError : AiService::NetworkError
    raise error_class, "Network error calling OpenAI: #{e.message}"
  end

  def request_body(route, system:, prompt:, history:, max_tokens:, response_schema:)
    body = {
      model:        route[:model],
      instructions: system,
      input:        history.map { |turn| { role: turn[:role], content: turn[:content] } } +
                    [ { role: "user", content: response_schema ? "#{prompt}\n\n#{JSON_MODE_REQUEST}" : prompt } ],
      store:        false,
      reasoning:    { effort: effort_for(route, capped: max_tokens.present?) }
    }
    # An allowance lets a capped call reason: the cap grows by it, leaving
    # room for reasoning on top of the reply the caller sized the cap for.
    body[:max_output_tokens] = max_tokens + route.fetch(:reasoning_allowance, 0) if max_tokens
    # JSON mode rather than the schema itself: strict schemas need an object at
    # the root and every property required, and VerdictSchema builds an anyOf
    # with optional fields. JSON mode guarantees a parseable reply, and each
    # verdict's .parse still holds the shape.
    body[:text] = { format: { type: "json_object" } } if response_schema
    body
  end

  # OpenAI answers an account with no credit with a 429 whose error code is
  # insufficient_quota, the same status as a rate limit. It is not one:
  # waiting never clears it, so it is told apart here and never retried as a
  # rate limit by anything downstream. A 402 is read the same way.
  INSUFFICIENT_QUOTA = "insufficient_quota".freeze
  RATE_LIMIT_FAMILIES = %w[requests tokens].freeze

  def raise_for_status(resp)
    raise_if_key_rejected("OpenAI", resp.status)
    error = parse_error_body(resp.body).fetch("error", {})
    raise_if_out_of_credit(error, resp.status)

    if resp.status == 429
      raise AiService::RateLimitError.new("OpenAI API error 429", http_status: 429,
                                          quota_id: quota_id_from(resp, error), retry_after: retry_after_seconds(resp))
    end

    log_raw_snippet("OpenAI API error #{resp.status} body", resp.body)
    message = extract_provider_message(resp.body, fallback: "OpenAI API error #{resp.status}")
    raise AiService::Error.new(message, http_status: resp.status)
  end

  def raise_if_out_of_credit(error, status)
    return unless status == 402 || (status == 429 && error["code"] == INSUFFICIENT_QUOTA)

    Rails.logger.warn("OpenAI reports the account is out of credit (HTTP #{status}, #{error['code']})")
    raise AiService::BillingError.new("OpenAI reports the account is out of credit", http_status: status)
  end

  def quota_id_from(resp, error)
    family = RATE_LIMIT_FAMILIES.find { |name| resp.headers["x-ratelimit-remaining-#{name}"].to_s == "0" }
    family ? "x-ratelimit-#{family}" : error["code"].presence || "rate_limit_exceeded"
  end

  def routed_model(purpose) = route_for(purpose)[:model]

  def read_result(parsed, route)
    usage = read_usage(parsed["usage"] || {}, route)
    unless %w[completed incomplete].include?(parsed["status"])
      return usage.merge(error: "OpenAI did not complete its response. Try again.")
    end

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
      # OpenAI includes both cache reads and writes in input_tokens.
      input_tokens:  usage["input_tokens"].to_i - cached_tokens - cache_write_tokens,
      # Reasoning tokens are already inside output_tokens.
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
    REASONING_OFF.fetch(model) { raise AiService::UnsupportedRouteError, "#{model} cannot turn reasoning off, so it cannot take a capped call" }
  end

  # A content filter stops a reply as "incomplete", the same status a spent
  # budget gives, so it is told apart here rather than read as truncation.
  def filtered?(parsed)
    parsed.dig("incomplete_details", "reason") == "content_filter"
  end

  def refusal_category(parsed, content)
    return "content_filter" if filtered?(parsed)

    "unspecified" if content.any? { |part| part["type"] == "refusal" }
  end

  def build_connection
    Faraday.new do |f|
      f.options.open_timeout     = OPEN_TIMEOUT
      f.options.timeout          = READ_TIMEOUT
      f.headers["authorization"] = "Bearer #{@api_key}"
      f.headers["content-type"]  = "application/json"
      f.request :retry, RETRY_OPTIONS
      f.adapter :net_http
    end
  end
end
