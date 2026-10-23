require "rails_helper"

RSpec.describe RecognitionGuidePrompt do
  def generate(group_key)
    subject_line = RecognitionGuide::NAMED_GROUP_SUBJECTS.fetch(group_key) { LanguagePrompts.for(group_key).fetch(:focus) }
    described_class.generate(group_key: group_key, subject: subject_line)
  end

  def prompt_for(group_key) = generate(group_key)[:prompt]

  # One case per branch: plain, a framing line, tradeoff concepts in a language-independent bucket and in a named group.
  %w[code_smell meta_skill architecture data_modeling].each do |group_key|
    it "renders #{group_key} exactly as recorded" do
      request = generate(group_key)

      expect(request.keys).to eq(%i[system prompt])
      expect_prompt_snapshot("recognition_guide__#{group_key}__system", request[:system])
      expect_prompt_snapshot("recognition_guide__#{group_key}__prompt", request[:prompt])
    end
  end

  it "cannot see an exercise, a response or history, because it takes only the group and its subject" do
    expect(described_class.method(:generate).parameters).to eq([ [ :keyreq, :group_key ], [ :keyreq, :subject ] ])
  end

  it "frames the tradeoff concepts a group holds as choices, and no others" do
    architecture = prompt_for("architecture")
    data_modeling = prompt_for("data_modeling")

    expect(architecture).to include("choices between two defensible options")
    expect(architecture[/Some of these \((.*?)\)/, 1].split(", "))
      .to match_array(ConceptVocabulary::ARCHITECTURE_CONCEPTS & ConceptVocabulary::TRADEOFF_CONCEPTS)
    expect(data_modeling[/Some of these \((.*?)\)/, 1]).to eq("denormalization_tradeoffs")
    expect(prompt_for("code_smell")).not_to include("choices between two defensible options")
  end

  it "frames meta skill as the habit its tracked concepts exercise, and only meta skill" do
    expect(prompt_for("meta_skill")).to include(RecognitionGuide::FRAMINGS.fetch("meta_skill"))
    expect(prompt_for("code_smell")).not_to include(RecognitionGuide::FRAMINGS.fetch("meta_skill"))
  end
end
