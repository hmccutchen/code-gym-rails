require "rails_helper"

RSpec.describe ClaudeService do
  let(:service) { ClaudeService.new("sk-ant-test") }
  let(:user) { User.create!(email: "prompt@example.com", name: "Prompt") }

  describe "EXERCISE_SCHEMA" do
    it "defines a teaching_note for each of the three sections" do
      expect(ClaudeService::EXERCISE_SCHEMA.scan('"teaching_note"').size).to eq(3)
    end
  end

  describe "#build_exercise_prompt" do
    it "instructs that teaching notes hint without giving the answer" do
      prompt = service.send(:build_exercise_prompt, user)
      expect(prompt).to include("teaching_note")
      expect(prompt.downcase).to include("never the full answer")
    end
  end

  describe "CONCEPTS" do
    it "is a frozen 16-entry vocabulary" do
      expect(ClaudeService::CONCEPTS.size).to eq(16)
      expect(ClaudeService::CONCEPTS).to be_frozen
      expect(ClaudeService::CONCEPTS).to include("n_plus_one", "transaction_safety", "error_handling")
    end
  end

  describe "EXERCISE_SCHEMA concept field" do
    it "defines a concept for each of the three sections" do
      expect(ClaudeService::EXERCISE_SCHEMA.scan('"concept"').size).to eq(3)
    end
  end

  describe "#normalize_concepts" do
    it "raises ClaudeService::Error for valid JSON that is not an object" do
      expect {
        service.send(:normalize_concepts, [ "not", "a", "problem set" ])
      }.to raise_error(ClaudeService::Error, /Array instead of a JSON object/)
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

  describe "#build_exercise_prompt with tagged history" do
    it "embeds the vocabulary, the mastery loop, and per-session concepts with correct rating labels" do
      exercise = DailyExercise.create!(user: user, date: Date.current,
                                       problem_set: { "code_review" => {} }, generated_at: Time.current)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "x" * 20 }, rating: :too_hard,
                            concept_tags: { "code_review" => "n_plus_one" })

      prompt = service.send(:build_exercise_prompt, user)
      expect(prompt).to include(ClaudeService::CONCEPTS.join(", "))
      expect(prompt).to include("mastery signal")
      expect(prompt).to include("concepts: n_plus_one")
      expect(prompt).to include("too hard")
      expect(prompt).not_to include("unrated")
    end
  end
end
