require "rails_helper"

RSpec.describe AiService, "#annotate_retention_concept" do
  include GenerationPromptHelpers

  let(:check) { ConceptMastery.new(concept: "memoization", language: "ruby_rails") }
  let(:kinds) { [ ExerciseSection::CodeReview, ExerciseSection::Pattern ] }
  let(:rungs) { kinds.index_with { "junior" } }

  it "names code_review as a host on a day it can take the check" do
    expect(generation_retention_annotation.call(check, kinds, "ruby_rails", :application_code, rungs))
      .to eq("memoization (code_review or pattern)")
  end

  it "names no bug_hunt code_review, which never carries a retention check" do
    expect(generation_retention_annotation.call(check, kinds, "ruby_rails", :bug_hunt, rungs)).to eq("memoization (pattern)")
  end
end
