require "faraday"
require "faraday/retry"

class GeminiService < AiService
  MODEL   = "gemini-3.5-flash"
  API_URL = "https://generativelanguage.googleapis.com/v1beta/interactions"

  # MODEL thinks at "medium" effort unless told otherwise, and thinking tokens
  # are generated into — and billed as — the same output budget max_output_tokens
  # caps. So a tight cap shared with default-effort thinking risks the model
  # spending the budget reasoning and returning little or no reply text, which
  # surfaces here as a truncated response rather than as anything diagnosable.
  # Every capped caller asks for a short, shape-constrained answer, so minimal
  # is the right effort for all of them.
  #
  # This is the closest analogue to ClaudeService's `thinking: disabled`, but it
  # is NOT the same thing: Gemini 3 Flash models have no full off switch, and
  # "minimal" is documented as the least thinking the model can do while still
  # producing thought signatures. So a capped Gemini call still spends some
  # budget before it answers, where the equivalent Claude call spends none —
  # which is why the caps stay sized with headroom rather than trimmed to the
  # reply alone.
  MINIMAL_THINKING_LEVEL = "minimal".freeze

  # 3 total attempts, exponential backoff capped at 8s. `methods: []` forces
  # every retry decision through `retry_if` — faraday-retry treats a method on
  # its `methods` list as retryable outright and never consults `retry_if`, and
  # POST (which every call here uses) has to be on one list or the other or no
  # retry ever fires. 429 matters most here: the
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
    methods:             [],
    retry_if:            AiService::RETRY_TIMEOUT_GUARD,
    retry_statuses:      [ 429, 500, 502, 503, 504 ]
  }.freeze

  private

  def call(system:, prompt:, cache_system: false, read_timeout: READ_TIMEOUT, max_tokens: nil, history: [])
    body = {
      model:              MODEL,
      system_instruction: system,
      input:              flatten_history(history, prompt),
      store:              false
    }
    # No default output cap is sent otherwise — existing callers rely on the
    # provider's own default ceiling, and on the model's default thinking
    # effort with it. Only a call that explicitly asks for a tighter cap (e.g.
    # AiService::DUCK_RESPONSE_MAX_TOKENS) sets this.
    #
    # The cap and the thinking level travel together deliberately: asking for a
    # tight budget without also asking for minimal thinking is what lets the
    # model spend that budget reasoning (see MINIMAL_THINKING_LEVEL). Both must
    # be nested under generation_config — the Interactions API ignores a
    # top-level max_output_tokens, which would silently drop the cap.
    if max_tokens
      body[:generation_config] = { max_output_tokens: max_tokens, thinking_level: MINIMAL_THINKING_LEVEL }
    end

    resp = @conn.post(API_URL, body.to_json) do |req|
      req.options.timeout = read_timeout
      req.options.context = (req.options.context || {}).merge(long_running: read_timeout > READ_TIMEOUT)
    end

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
    output_tokens = usage["total_output_tokens"]

    {
      text:          text_parts.join,
      input_tokens:  usage["total_input_tokens"],
      output_tokens: output_tokens,
      # The Interactions API response carries no explicit stop/finish-reason
      # field (unlike Claude's stop_reason) — without this, call_and_log's
      # truncation check is silently always false here. A capped call (e.g.
      # AiService::DUCK_RESPONSE_MAX_TOKENS) that actually hits its ceiling
      # is inferred from output landing at or past what was requested, so a
      # Gemini user gets the same clean truncation error a Claude user would
      # instead of a silently cut-off reply. Uncapped calls (max_tokens nil)
      # never flag truncated, matching their pre-existing behavior.
      truncated: max_tokens.present? && output_tokens.to_i >= max_tokens
    }
  rescue Faraday::Error => e
    error_class = e.is_a?(Faraday::TimeoutError) ? AiService::TimeoutError : AiService::Error
    raise error_class, "Network error calling Gemini: #{e.message}"
  end

  def build_connection
    Faraday.new do |f|
      f.options.open_timeout      = OPEN_TIMEOUT
      f.options.timeout           = READ_TIMEOUT
      f.headers["x-goog-api-key"] = @api_key
      f.headers["content-type"]   = "application/json"
      f.request :retry, RETRY_OPTIONS
      f.adapter :net_http
    end
  end
end
