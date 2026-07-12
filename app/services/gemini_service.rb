require "faraday"
require "faraday/retry"

class GeminiService < AiService
  MODEL   = "gemini-3.5-flash"
  API_URL = "https://generativelanguage.googleapis.com/v1beta/interactions"

  private

  def call(system:, prompt:)
    body = {
      model:              MODEL,
      system_instruction: system,
      input:              prompt,
      store:              false
    }

    resp = @conn.post(API_URL, body.to_json)

    raise AiService::Error, "Gemini API error #{resp.status}: #{resp.body}" unless resp.success?

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
      f.request :retry, max: 2, interval: 1, retry_statuses: [ 429, 503 ]
      f.adapter :net_http
    end
  end
end
