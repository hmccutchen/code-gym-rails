require "rails_helper"

RSpec.describe PseudocodePrompt do
  let(:section) { ExerciseSection::PseudocodeToCode.key }
  let(:exercise) do
    DailyExercise.new(language: "javascript",
                      problem_set: { section => { "problem_statement" => "Merge overlapping ranges." } })
  end
  let(:pseudocode) { "sort ranges, then walk them" }

  it "gives the critique its system prompt with the user-text rule, and the problem, the plan and the gap standard" do
    request = described_class.critique(exercise, section, pseudocode)

    expect(request.keys).to eq(%i[system prompt])
    expect(request[:system]).to eq("#{described_class::CRITIQUE_SYSTEM}\n\n#{UserText::PROMPT_RULE}")
    expect(request[:prompt]).to include("Merge overlapping ranges.", UserText.tagged(pseudocode),
                                        ExerciseSection::PseudocodeToCode.gap_standard)
  end

  it "gives the translation its system prompt with the user-text rule, and names the exercise's language" do
    request = described_class.translate(exercise, section, pseudocode)

    expect(request[:system]).to eq("#{described_class::TRANSLATE_SYSTEM}\n\n#{UserText::PROMPT_RULE}")
    expect(request[:prompt]).to include("Target language: #{AiService.config_for('javascript')[:label]}.",
                                        UserText.tagged(pseudocode))
  end
end
