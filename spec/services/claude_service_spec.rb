require "rails_helper"

RSpec.describe ClaudeService do
  let(:service) { described_class.new("sk-ant-test") }

  describe "#build_connection" do
    it "sets Anthropic auth headers" do
      conn = service.send(:build_connection)
      expect(conn.headers["x-api-key"]).to eq("sk-ant-test")
      expect(conn.headers["anthropic-version"]).to eq("2023-06-01")
    end
  end

  describe "#call" do
    it "posts the Anthropic-shaped request body and normalizes the response" do
      fake_response = instance_double(Faraday::Response, success?: true, status: 200,
        body: {
          "content" => [ { "type" => "text", "text" => "hello" } ],
          "usage"   => { "input_tokens" => 10, "output_tokens" => 20 }
        }.to_json)
      fake_conn = instance_double(Faraday::Connection)
      service.instance_variable_set(:@conn, fake_conn)

      expect(fake_conn).to receive(:post) do |url, body|
        expect(url).to eq(ClaudeService::API_URL)
        parsed = JSON.parse(body)
        expect(parsed["model"]).to eq(ClaudeService::MODEL)
        expect(parsed["system"]).to eq("sys")
        expect(parsed["messages"]).to eq([ { "role" => "user", "content" => "prompt text" } ])
        fake_response
      end

      result = service.send(:call, system: "sys", prompt: "prompt text")
      expect(result).to eq(text: "hello", input_tokens: 10, output_tokens: 20)
    end

    it "raises AiService::Error on a non-success response" do
      fake_response = instance_double(Faraday::Response, success?: false, status: 500, body: "boom")
      fake_conn = instance_double(Faraday::Connection, post: fake_response)
      service.instance_variable_set(:@conn, fake_conn)

      expect {
        service.send(:call, system: "sys", prompt: "prompt")
      }.to raise_error(AiService::Error, /Claude API error 500/)
    end

    it "does not leak the raw response body into the exception message" do
      huge_body = "error detail " * 100
      fake_response = instance_double(Faraday::Response, success?: false, status: 500, body: huge_body)
      fake_conn = instance_double(Faraday::Connection, post: fake_response)
      service.instance_variable_set(:@conn, fake_conn)

      expect {
        service.send(:call, system: "sys", prompt: "prompt")
      }.to raise_error(AiService::Error) { |e| expect(e.message).not_to include(huge_body) }
    end

    it "logs a truncated snippet of the raw response body server-side" do
      huge_body = "y" * 1000
      fake_response = instance_double(Faraday::Response, success?: false, status: 500, body: huge_body)
      fake_conn = instance_double(Faraday::Connection, post: fake_response)
      service.instance_variable_set(:@conn, fake_conn)

      expect(Rails.logger).to receive(:error) do |msg|
        expect(msg).to include("Claude API error 500 body")
        expect(msg).to include("truncated, #{huge_body.bytesize} bytes total")
      end

      expect { service.send(:call, system: "sys", prompt: "prompt") }.to raise_error(AiService::Error)
    end
  end
end
