require "rails_helper"

RSpec.describe GeminiService do
  let(:service) { described_class.new("AIzaTestKey") }

  describe "#build_connection" do
    it "sets the Gemini auth header" do
      conn = service.send(:build_connection)
      expect(conn.headers["x-goog-api-key"]).to eq("AIzaTestKey")
    end
  end

  describe "#call" do
    it "posts the Gemini-shaped request body and extracts text + usage from the model_output step" do
      fake_response = instance_double(Faraday::Response, success?: true, status: 200,
        body: {
          "steps" => [
            { "type" => "thought" },
            { "type" => "model_output", "content" => [ { "type" => "text", "text" => "hello" } ] }
          ],
          "usage" => { "total_input_tokens" => 8, "total_output_tokens" => 12 }
        }.to_json)
      fake_conn = instance_double(Faraday::Connection)
      service.instance_variable_set(:@conn, fake_conn)

      expect(fake_conn).to receive(:post) do |url, body|
        expect(url).to eq(GeminiService::API_URL)
        parsed = JSON.parse(body)
        expect(parsed["model"]).to eq(GeminiService::MODEL)
        expect(parsed["system_instruction"]).to eq("sys")
        expect(parsed["input"]).to eq("prompt text")
        expect(parsed["store"]).to eq(false)
        fake_response
      end

      result = service.send(:call, system: "sys", prompt: "prompt text")
      expect(result).to eq(text: "hello", input_tokens: 8, output_tokens: 12)
    end

    it "raises AiService::Error on a non-success response" do
      fake_response = instance_double(Faraday::Response, success?: false, status: 503, body: "overloaded")
      fake_conn = instance_double(Faraday::Connection, post: fake_response)
      service.instance_variable_set(:@conn, fake_conn)

      expect {
        service.send(:call, system: "sys", prompt: "prompt")
      }.to raise_error(AiService::Error, /Gemini API error 503/)
    end
  end
end
