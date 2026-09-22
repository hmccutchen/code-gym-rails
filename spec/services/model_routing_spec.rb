require "rails_helper"

RSpec.describe "per-purpose model routing" do
  let(:purposes_in_use) do
    File.read(Rails.root.join("app/services/ai_service.rb")).scan(/purpose: "(\w+)"/).flatten.uniq
  end

  def posted_body(service_class, **kwargs)
    bodies = []
    service = service_class.new("test-key")
    conn = Faraday.new do |f|
      f.adapter :test do |stub|
        stub.post(service_class::API_URL) do |env|
          bodies << JSON.parse(env.body)
          [ 200, {}, success_body_for(service_class) ]
        end
      end
    end
    service.instance_variable_set(:@conn, conn)
    service.send(:call, system: "sys", prompt: "p", **kwargs)
    bodies.sole
  end

  def success_body_for(service_class)
    if service_class == ClaudeService
      { "content" => [ { "type" => "text", "text" => "ok" } ],
        "usage" => { "input_tokens" => 1, "output_tokens" => 1 } }.to_json
    else
      { "steps" => [ { "type" => "model_output", "content" => [ { "type" => "text", "text" => "ok" } ] } ],
        "usage" => { "total_input_tokens" => 1, "total_output_tokens" => 1 } }.to_json
    end
  end

  # An unlisted purpose falls back to the default route, so a misspelled key
  # would silently route nothing. This is what makes that fallback safe.
  [ ClaudeService, GeminiService ].each do |service_class|
    it "routes only purposes #{service_class} actually logs" do
      expect(service_class::MODEL_FOR_PURPOSE.keys - purposes_in_use).to be_empty
    end

    it "sends #{service_class}'s default model for a purpose with no entry" do
      body = posted_body(service_class, purpose: "not_a_listed_purpose")

      expect(body["model"]).to eq(service_class::DEFAULT_ROUTE[:model])
    end
  end

  # Everything above drives #call directly, so none of it would notice
  # call_and_log dropping the purpose on the way down — the real generation
  # call would quietly fall back to the default model.
  it "routes the generation call made through call_and_log, not only a direct #call" do
    user     = User.create!(email: "routing@example.com", name: "Routing")
    bodies   = []
    service  = ClaudeService.new("sk-ant-test")
    connection = Faraday.new do |f|
      f.adapter :test do |stub|
        stub.post(ClaudeService::API_URL) do |env|
          bodies << JSON.parse(env.body)
          [ 200, {}, { "content" => [ { "type" => "text", "text" => FakeService::EXERCISE_PROBLEM_SET.to_json } ],
                       "usage" => { "input_tokens" => 1, "output_tokens" => 1 } }.to_json ]
        end
      end
    end
    service.instance_variable_set(:@conn, connection)

    service.generate_exercise(user, language: "ruby_rails")

    expect(bodies.sole["model"]).to eq(ClaudeService::MODEL_FOR_PURPOSE.fetch("generate_exercise")[:model])
  end

  describe ClaudeService do
    it "sends generation to Opus at medium effort" do
      body = posted_body(ClaudeService, purpose: "generate_exercise")

      expect(body["model"]).to eq("claude-opus-5-5")
      expect(body["output_config"]).to eq("effort" => "medium")
    end

    it "keeps review, duck and pseudocode translation on the default model until the comparison is read" do
      %w[review_response duck_thread pseudocode_translate].each do |purpose|
        expect(ClaudeService::MODEL_FOR_PURPOSE).not_to have_key(purpose)
      end
    end

    it "sends no effort for a route that names none" do
      body = posted_body(ClaudeService, purpose: "review_response")

      expect(body).not_to have_key("output_config")
    end

    # Haiku 4.5 rejects the effort parameter with a 400.
    it "never pairs an effort with a model that rejects one" do
      ClaudeService::MODEL_FOR_PURPOSE.each_value do |route|
        expect(route[:model]).not_to start_with("claude-haiku") if route[:effort]
      end
    end
  end
end
