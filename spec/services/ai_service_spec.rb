require "rails_helper"

RSpec.describe AiService do
  let(:user) { User.create!(email: "prompt@example.com", name: "Prompt") }

  # Minimal concrete subclass so AiService's shared logic can be exercised
  # without a real network call to any provider.
  let(:double_class) do
    Class.new(AiService) do
      def initialize(canned_text: "{}", input_tokens: 1, output_tokens: 1)
        @canned_text   = canned_text
        @input_tokens  = input_tokens
        @output_tokens = output_tokens
      end

      private

      def call(system:, prompt:)
        { text: @canned_text, input_tokens: @input_tokens, output_tokens: @output_tokens }
      end

      def build_connection
        nil
      end
    end
  end

  let(:service) { double_class.new }

  describe "#exercise_schema_for" do
    it "defines a teaching_note and a concept for each of the three sections, for any language" do
      %w[ruby_rails javascript].each do |language|
        schema = service.send(:exercise_schema_for, language)
        expect(schema.scan('"teaching_note"').size).to eq(3)
        expect(schema.scan('"concept"').size).to eq(3)
      end
    end

    it "labels code fields with Ruby/Rails for ruby_rails" do
      schema = service.send(:exercise_schema_for, "ruby_rails")
      expect(schema).to include("Ruby/Rails code")
    end

    it "labels code fields with JavaScript/React for javascript" do
      schema = service.send(:exercise_schema_for, "javascript")
      expect(schema).to include("JavaScript/React code")
    end

    it "defaults to ruby_rails when no language is given" do
      expect(service.send(:exercise_schema_for)).to eq(service.send(:exercise_schema_for, "ruby_rails"))
    end
  end

  describe "#build_system_prompt" do
    it "focuses on Rails patterns for ruby_rails" do
      prompt = service.send(:build_system_prompt, "ruby_rails")
      expect(prompt).to include("senior Rails engineering coach")
      expect(prompt).to include("N+1 queries")
    end

    it "focuses on JavaScript/React patterns for javascript" do
      prompt = service.send(:build_system_prompt, "javascript")
      expect(prompt).to include("senior JavaScript/React engineering coach")
      expect(prompt).to include("hooks")
    end

    it "defaults to ruby_rails when no language is given" do
      expect(service.send(:build_system_prompt)).to eq(service.send(:build_system_prompt, "ruby_rails"))
    end

    it "raises instead of silently falling back on an unsupported language" do
      expect { service.send(:build_system_prompt, "mixed") }
        .to raise_error(AiService::Error, /Unsupported generation language/)
    end
  end

  describe "RAILS_CONCEPTS" do
    it "is a frozen 16-entry vocabulary" do
      expect(AiService::RAILS_CONCEPTS.size).to eq(16)
      expect(AiService::RAILS_CONCEPTS).to be_frozen
      expect(AiService::RAILS_CONCEPTS).to include("n_plus_one", "transaction_safety", "error_handling")
    end
  end

  describe "JS_CONCEPTS" do
    it "is a frozen 14-entry vocabulary" do
      expect(AiService::JS_CONCEPTS.size).to eq(14)
      expect(AiService::JS_CONCEPTS).to be_frozen
      expect(AiService::JS_CONCEPTS).to include("closures", "prototype_chain", "hooks_dependencies")
    end
  end

  describe "#build_exercise_prompt" do
    it "instructs that teaching notes hint without giving the answer" do
      prompt = service.send(:build_exercise_prompt, user)
      expect(prompt).to include("teaching_note")
      expect(prompt.downcase).to include("never the full answer")
    end

    it "embeds the vocabulary, the mastery loop, and per-session concepts with correct rating labels" do
      exercise = DailyExercise.create!(user: user, date: Date.current,
                                       problem_set: { "code_review" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "x" * 20 }, rating: :too_hard,
                            concept_tags: { "code_review" => "n_plus_one" })

      prompt = service.send(:build_exercise_prompt, user)
      expect(prompt).to include(AiService::RAILS_CONCEPTS.join(", "))
      expect(prompt).to include("mastery signal")
      expect(prompt).to include("concepts: n_plus_one")
      expect(prompt).to include("too hard")
      expect(prompt).not_to include("unrated")
    end

    it "uses the JS/React vocabulary and JavaScript/React labeling when language is javascript" do
      prompt = service.send(:build_exercise_prompt, user, "javascript")
      expect(prompt).to include(AiService::JS_CONCEPTS.join(", "))
      expect(prompt).to include("JavaScript/React code")
      expect(prompt).not_to include(AiService::RAILS_CONCEPTS.join(", "))
    end

    it "defaults to ruby_rails vocabulary when no language is given" do
      prompt = service.send(:build_exercise_prompt, user)
      expect(prompt).to include(AiService::RAILS_CONCEPTS.join(", "))
    end
  end

  describe "#normalize_concepts" do
    it "keeps on-list concepts and maps off-list ones to 'other'" do
      set = {
        "code_review" => { "concept" => "n_plus_one" },
        "pattern" => { "concept" => "N+1 Queries!!" },
        "challenge" => { "question" => "no concept key" }
      }
      out = service.send(:normalize_concepts, set)
      expect(out["code_review"]["concept"]).to eq("n_plus_one")
      expect(out["pattern"]["concept"]).to eq("other")
      expect(out["challenge"]).not_to have_key("concept")
    end

    it "validates against the JS vocabulary when language is javascript" do
      set = {
        "code_review" => { "concept" => "closures" },
        "pattern" => { "concept" => "n_plus_one" }
      }
      out = service.send(:normalize_concepts, set, "javascript")
      expect(out["code_review"]["concept"]).to eq("closures")
      expect(out["pattern"]["concept"]).to eq("other")
    end
  end

  describe "#parse_json_response" do
    it "strips markdown fences before parsing" do
      fenced = "```json\n{\"a\":1}\n```"
      expect(service.send(:parse_json_response, fenced)).to eq("a" => 1)
    end

    it "raises AiService::Error for invalid JSON" do
      expect {
        service.send(:parse_json_response, "not json")
      }.to raise_error(AiService::Error, /invalid JSON/)
    end

    it "does not leak the raw provider text into the exception message" do
      huge_text = "garbage " * 200
      expect {
        service.send(:parse_json_response, huge_text)
      }.to raise_error(AiService::Error) { |e| expect(e.message).not_to include(huge_text) }
    end

    it "logs a truncated snippet of the raw provider text server-side" do
      huge_text = "x" * 1000
      expect(Rails.logger).to receive(:error) do |msg|
        expect(msg).to include("Invalid JSON from provider")
        expect(msg).to include("truncated, #{huge_text.bytesize} bytes total")
        expect(msg.length).to be < huge_text.length
      end

      expect { service.send(:parse_json_response, huge_text) }.to raise_error(AiService::Error)
    end
  end

  describe "#extract_provider_message" do
    it "returns the provider's error.message when the body is a matching JSON error object" do
      body = {
        "type"  => "error",
        "error" => { "type" => "insufficient_quota", "message" => "Your credit balance is too low to access the Anthropic API." }
      }.to_json

      expect(service.send(:extract_provider_message, body, fallback: "fallback text"))
        .to eq("Your credit balance is too low to access the Anthropic API.")
    end

    it "falls back when the body is not JSON" do
      expect(service.send(:extract_provider_message, "not json", fallback: "fallback text"))
        .to eq("fallback text")
    end

    it "falls back when the JSON body has no error.message" do
      body = { "type" => "error", "error" => { "type" => "overloaded_error" } }.to_json

      expect(service.send(:extract_provider_message, body, fallback: "fallback text"))
        .to eq("fallback text")
    end

    it "falls back when error.message is blank" do
      body = { "error" => { "message" => "" } }.to_json

      expect(service.send(:extract_provider_message, body, fallback: "fallback text"))
        .to eq("fallback text")
    end

    it "falls back when the body is nil instead of raising" do
      expect(service.send(:extract_provider_message, nil, fallback: "fallback text"))
        .to eq("fallback text")
    end

    it "falls back when the body is not a String instead of raising" do
      expect(service.send(:extract_provider_message, 123, fallback: "fallback text"))
        .to eq("fallback text")
    end
  end

  describe "#generate_exercise" do
    it "raises rather than returning a problem set that isn't a JSON object" do
      svc = double_class.new(canned_text: '["not", "a", "problem set"]')

      expect {
        svc.generate_exercise(user)
      }.to raise_error(AiService::Error, /Array instead of a JSON object/)
    end

    it "logs usage and normalizes concepts from the provider's response using the resolved language" do
      set = { "code_review" => { "concept" => "bogus" } }
      svc = double_class.new(canned_text: set.to_json, input_tokens: 5, output_tokens: 7)

      result = svc.generate_exercise(user)

      expect(result["code_review"]["concept"]).to eq("other")
      usage = ApiUsage.last
      expect(usage.tokens_in).to eq(5)
      expect(usage.tokens_out).to eq(7)
      expect(usage.purpose).to eq("generate_exercise")
    end

    it "normalizes against the JS vocabulary when an explicit javascript language is passed" do
      set = { "code_review" => { "concept" => "closures" } }
      svc = double_class.new(canned_text: set.to_json)

      result = svc.generate_exercise(user, language: "javascript")

      expect(result["code_review"]["concept"]).to eq("closures")
    end

    it "defaults language to the user's language_for_today when not passed explicitly" do
      user.update!(language: "javascript")
      set = { "code_review" => { "concept" => "closures" } }
      svc = double_class.new(canned_text: set.to_json)

      result = svc.generate_exercise(user)

      expect(result["code_review"]["concept"]).to eq("closures")
    end
  end

  describe "#review_response" do
    def sample_exercise(language)
      DailyExercise.new(
        language: language,
        problem_set: {
          "code_review" => { "question" => "q", "snippet" => "s" },
          "pattern" => { "title" => "t", "question" => "q" },
          "challenge" => { "question" => "q" }
        }
      )
    end

    it "names Rails in the system prompt for a ruby_rails exercise" do
      spy_class = Class.new(double_class) do
        attr_reader :last_system

        def call(system:, prompt:)
          @last_system = system
          super
        end
      end
      svc = spy_class.new

      svc.review_response(user, sample_exercise("ruby_rails"), instance_double(DailyResponse, answers: {}))

      expect(svc.last_system).to include("senior Rails engineer")
    end

    it "names JavaScript/React in the system prompt for a javascript exercise" do
      spy_class = Class.new(double_class) do
        attr_reader :last_system

        def call(system:, prompt:)
          @last_system = system
          super
        end
      end
      svc = spy_class.new

      svc.review_response(user, sample_exercise("javascript"), instance_double(DailyResponse, answers: {}))

      expect(svc.last_system).to include("senior JavaScript/React engineer")
    end

    it "returns the AI service's stubbed feedback for the submitted answers to each JSON question" do
      exercise = sample_exercise("ruby_rails")
      daily_response = instance_double(DailyResponse, answers: {
        "code_review" => "It's an N+1 query — fix with includes.",
        "pattern"     => "Extract a scope object.",
        "challenge"   => "def foo; end"
      })

      feedback = {
        "code_review" => { "rating" => "solid", "correct" => "Spotted the N+1", "missed" => "", "better_questions" => "", "next_step" => "", "improved_code" => "" },
        "pattern"     => { "rating" => "developing", "correct" => "", "missed" => "Missed the edge case", "better_questions" => "", "next_step" => "", "improved_code" => "" },
        "challenge"   => { "rating" => "strong", "correct" => "Works as specified", "missed" => "", "better_questions" => "", "next_step" => "", "improved_code" => "" }
      }

      spy_class = Class.new(double_class) do
        attr_reader :last_prompt

        def call(system:, prompt:)
          @last_prompt = prompt
          super
        end
      end
      svc = spy_class.new(canned_text: feedback.to_json)

      result = svc.review_response(user, exercise, daily_response)

      expect(result).to eq(feedback)
      expect(svc.last_prompt).to include(exercise.code_review["question"])
      expect(svc.last_prompt).to include("It's an N+1 query — fix with includes.")
      expect(svc.last_prompt).to include(exercise.pattern["question"])
      expect(svc.last_prompt).to include("Extract a scope object.")
      expect(svc.last_prompt).to include(exercise.challenge["question"])
      expect(svc.last_prompt).to include("def foo; end")
    end

    # A review that isn't a JSON object would still be truthy once persisted to
    # ai_review, which flips DailyResponse#reviewed? and permanently retires the
    # "Get review" button — leaving the user with an empty review and no retry.
    it "raises rather than returning a review that isn't a JSON object" do
      svc = double_class.new(canned_text: '["not", "an", "object"]')

      expect {
        svc.review_response(user, sample_exercise("ruby_rails"), instance_double(DailyResponse, answers: {}))
      }.to raise_error(AiService::Error, /instead of a JSON object/)
    end
  end

  describe ".for" do
    it "returns a ClaudeService for an anthropic user" do
      user.update!(api_key: "sk-ant-test", provider: "anthropic")
      expect(AiService.for(user)).to be_a(ClaudeService)
    end

    it "returns a GeminiService for a gemini user" do
      user.update!(api_key: "AIzaTest", provider: "gemini")
      expect(AiService.for(user)).to be_a(GeminiService)
    end

    it "raises AiService::Error when the user has no recognized provider" do
      expect { AiService.for(user) }.to raise_error(AiService::Error, /no recognized AI provider/)
    end
  end
end
