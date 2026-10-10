module ProviderSuccessBodies
  def provider_success_body(service_class, text: "ok")
    body =
      case service_class.name
      when "ClaudeService"
        { "content" => [ { "type" => "text", "text" => text } ],
          "usage" => { "input_tokens" => 1, "output_tokens" => 1 } }
      when "GeminiService"
        { "steps" => [ { "type" => "model_output", "content" => [ { "type" => "text", "text" => text } ] } ],
          "usage" => { "total_input_tokens" => 1, "total_output_tokens" => 1 } }
      when "OpenaiService"
        { "status" => "completed",
          "output" => [ { "type" => "message", "role" => "assistant", "content" => [ { "type" => "output_text", "text" => text } ] } ],
          "usage" => { "input_tokens" => 1, "output_tokens" => 1 } }
      else
        raise ArgumentError, "no success body for #{service_class}"
      end
    body.to_json
  end
end

RSpec.configure { |config| config.include ProviderSuccessBodies }
