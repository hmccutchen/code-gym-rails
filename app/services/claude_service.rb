require "faraday"
require "faraday/retry"

class ClaudeService < AiService
  MODEL   = "claude-sonnet-4-5"
  API_URL = "https://api.anthropic.com/v1/messages"

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
      raise AiService::Error, "Claude API error #{resp.status}"
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
      f.request :retry, max: 2, interval: 1, retry_statuses: [ 529 ]
      f.adapter :net_http
    end
  end
end
