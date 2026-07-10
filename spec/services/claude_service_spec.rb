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
end
