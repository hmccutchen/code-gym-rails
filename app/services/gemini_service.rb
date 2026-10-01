require "faraday"
require "faraday/retry"

class GeminiService < AiService
  API_URL = "https://generativelanguage.googleapis.com/v1beta/interactions"

  # Keyed by the ApiUsage purpose string, like ClaudeService's. Generation and
  # its single-section retry share the default route explicitly so route
  # coverage can pin both usage labels.
  DEFAULT_ROUTE = { model: "gemini-3.5-flash" }.freeze
  MODEL_FOR_PURPOSE = {
    "generate_exercise" => DEFAULT_ROUTE,
    "retry_section"     => DEFAULT_ROUTE
  }.freeze

  # The default model thinks at "medium" effort unless told otherwise, and
  # thinking tokens are generated into — and billed as — the same output budget
  # max_output_tokens caps. So a tight cap shared with default-effort thinking risks the model
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

  # response_schema is not sent yet, so a Gemini reply is held only by its
  # prompt and the caller's parse (#228).
  def call(system:, prompt:, cache_system: false, read_timeout: READ_TIMEOUT, max_tokens: nil, history: [], purpose: nil, response_schema: nil, single_attempt: false)
    body = {
      model:              MODEL_FOR_PURPOSE.fetch(purpose, DEFAULT_ROUTE)[:model],
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
      req.options.context = (req.options.context || {}).merge(long_running: read_timeout > READ_TIMEOUT, single_attempt: single_attempt)
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

    parsed       = parse_provider_envelope(resp.body, provider: "Gemini")
    model_output = Array(parsed["steps"]).find { |s| s["type"] == "model_output" }
    text_parts   = Array(model_output && model_output["content"]).select { |c| c["type"] == "text" }.map { |c| c["text"] }
    usage        = parsed["usage"] || {}
    output_tokens = usage["total_output_tokens"]
    cached_tokens = usage["total_cached_tokens"].to_i

    {
      text:          text_parts.join,
      # total_input_tokens includes the cached part, unlike Claude's
      # input_tokens; subtracting it keeps tokens_in the uncached input on
      # both providers, so a cached token is never priced twice.
      input_tokens:  usage["total_input_tokens"].to_i - cached_tokens,
      # Thinking is billed as output but reported apart from it: a live
      # response gave total_tokens = input + output + thought.
      output_tokens: output_tokens.to_i + usage["total_thought_tokens"].to_i,
      model:         body[:model],
      cache_read_tokens:  cached_tokens,
      cache_write_tokens: 0,
      # The API documents "incomplete" as completed with incomplete results,
      # hitting max_tokens being one cause, so the status decides and token
      # counts are not consulted: a live call capped at 60 stopped at 56
      # output tokens with this status.
      truncated: parsed["status"] == "incomplete"
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
