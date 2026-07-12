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

  describe "EXERCISE_SCHEMA" do
    it "defines a teaching_note and a concept for each of the three sections" do
      expect(AiService::EXERCISE_SCHEMA.scan('"teaching_note"').size).to eq(3)
      expect(AiService::EXERCISE_SCHEMA.scan('"concept"').size).to eq(3)
    end
  end

  describe "CONCEPTS" do
    it "is a frozen 16-entry vocabulary" do
      expect(AiService::CONCEPTS.size).to eq(16)
      expect(AiService::CONCEPTS).to be_frozen
      expect(AiService::CONCEPTS).to include("n_plus_one", "transaction_safety", "error_handling")
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
      expect(prompt).to include(AiService::CONCEPTS.join(", "))
      expect(prompt).to include("mastery signal")
      expect(prompt).to include("concepts: n_plus_one")
      expect(prompt).to include("too hard")
      expect(prompt).not_to include("unrated")
    end
  end

  describe "#normalize_concepts" do
    it "raises AiService::Error for valid JSON that is not an object" do
      expect {
        service.send(:normalize_concepts, [ "not", "a", "problem set" ])
      }.to raise_error(AiService::Error, /Array instead of a JSON object/)
    end

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
  end

  describe "#generate_exercise" do
    it "logs usage and normalizes concepts from the provider's response" do
      set = { "code_review" => { "concept" => "bogus" } }
      svc = double_class.new(canned_text: set.to_json, input_tokens: 5, output_tokens: 7)

      result = svc.generate_exercise(user)

      expect(result["code_review"]["concept"]).to eq("other")
      usage = ApiUsage.last
      expect(usage.tokens_in).to eq(5)
      expect(usage.tokens_out).to eq(7)
      expect(usage.purpose).to eq("generate_exercise")
    end
  end
end
