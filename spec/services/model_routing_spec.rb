require "rails_helper"

RSpec.describe "per-purpose model routing" do
  let(:purposes_in_use) do
    File.read(Rails.root.join("app/services/ai_service.rb")).scan(/purpose: "(\w+)"/).flatten.uniq
  end

  # The model a call reports is the one it routed to, so a usage row names the
  # model whose prices apply to it.
  [ ClaudeService, GeminiService, OpenaiService ].each do |service_class|
    it "reports the model #{service_class} routed each purpose to" do
      purposes = service_class::MODEL_FOR_PURPOSE.keys + [ "an_unlisted_purpose" ]

      purposes.each do |purpose|
        expected = service_class::MODEL_FOR_PURPOSE.fetch(purpose, service_class::DEFAULT_ROUTE)[:model]
        expect(result_for(service_class, purpose: purpose)[:model]).to eq(expected), "purpose #{purpose}"
      end
    end
  end

  def result_for(service_class, **kwargs)
    service = service_class.new("test-key")
    conn = Faraday.new do |f|
      f.adapter :test do |stub|
        stub.post(service_class::API_URL) { [ 200, {}, provider_success_body(service_class) ] }
      end
    end
    service.instance_variable_set(:@conn, conn)
    service.send(:call, system: "sys", prompt: "p", **kwargs)
  end

  def posted_body(service_class, **kwargs)
    bodies = []
    service = service_class.new("test-key")
    conn = Faraday.new do |f|
      f.adapter :test do |stub|
        stub.post(service_class::API_URL) do |env|
          bodies << JSON.parse(env.body)
          [ 200, {}, provider_success_body(service_class) ]
        end
      end
    end
    service.instance_variable_set(:@conn, conn)
    service.send(:call, system: "sys", prompt: "p", **kwargs)
    bodies.sole
  end


  # An unlisted purpose falls back to the default route, so a misspelled key
  # would silently route nothing. This is what makes that fallback safe.
  [ ClaudeService, GeminiService, OpenaiService ].each do |service_class|
    it "routes only purposes #{service_class} actually logs" do
      expect(service_class::MODEL_FOR_PURPOSE.keys - purposes_in_use).to be_empty
    end

    it "routes retry_section like generate_exercise for #{service_class}" do
      expect(service_class::MODEL_FOR_PURPOSE.fetch("retry_section"))
        .to eq(service_class::MODEL_FOR_PURPOSE.fetch("generate_exercise"))
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
    it "routes judge_review to Sonnet 5.5 at an explicit high effort" do
      expect(ClaudeService::MODEL_FOR_PURPOSE.fetch("judge_review")).to eq(model: "claude-sonnet-5-5", effort: "high")
    end

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

    it "sends the default route to Sonnet 5.5 at an explicit high effort" do
      body = posted_body(ClaudeService, purpose: "review_response")

      expect(body["model"]).to eq("claude-sonnet-5-5")
      expect(body["output_config"]).to eq("effort" => "high")
    end

    it "routes judge_section to Sonnet 5.5 at an explicit high effort" do
      body = posted_body(ClaudeService, purpose: "judge_section")

      expect(body["model"]).to eq("claude-sonnet-5-5")
      expect(body["output_config"]).to eq("effort" => "high")
    end

    # between_tools is rejected above high effort.
    it "keeps every between_tools route at high effort or below" do
      routes = ClaudeService::MODEL_FOR_PURPOSE.values + [ ClaudeService::DEFAULT_ROUTE ]
      routes.select { |route| ClaudeService::THINKING_OFF[route[:model]] == { type: "between_tools" } }.each do |route|
        expect([ nil, "low", "medium", "high" ]).to include(route[:effort])
      end
    end

    it "gives every non-generation route a thinking-off setting, since any of them may be capped" do
      generation = ClaudeService::MODEL_FOR_PURPOSE.values_at("generate_exercise", "retry_section")
      (ClaudeService::MODEL_FOR_PURPOSE.values + [ ClaudeService::DEFAULT_ROUTE ] - generation).each do |route|
        expect(ClaudeService::THINKING_OFF).to have_key(route[:model])
      end
    end

    # Haiku 4.5 rejects the effort parameter with a 400.
    it "never pairs an effort with a model that rejects one" do
      ClaudeService::MODEL_FOR_PURPOSE.each_value do |route|
        expect(route[:model]).not_to start_with("claude-haiku") if route[:effort]
      end
    end
  end

  describe OpenaiService do
    it "sends generation to 6.1 Sol at high effort" do
      body = posted_body(OpenaiService, purpose: "generate_exercise")

      expect(body["model"]).to eq("gpt-6.1-sol")
      expect(body["reasoning"]).to eq("effort" => "high")
    end

    it "sends the default route to 6 Sol at an explicit medium effort" do
      body = posted_body(OpenaiService, purpose: "review_response")

      expect(body["model"]).to eq("gpt-6-sol")
      expect(body["reasoning"]).to eq("effort" => "medium")
    end

    it "gives every non-generation route a reasoning-off setting, since any of them may be capped" do
      generation = OpenaiService::MODEL_FOR_PURPOSE.values_at("generate_exercise", "retry_section")
      (OpenaiService::MODEL_FOR_PURPOSE.values + [ OpenaiService::DEFAULT_ROUTE ] - generation).each do |route|
        expect(OpenaiService::REASONING_OFF).to have_key(route[:model])
      end
    end
  end
end
