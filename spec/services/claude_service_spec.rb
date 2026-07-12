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
  end
end
