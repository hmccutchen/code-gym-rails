require "rails_helper"

RSpec.describe AiService, "#annotate_retention_concept" do
  include GenerationPromptHelpers

  let(:check) { ConceptMastery.new(concept: "memoization", language: "ruby_rails") }
  let(:kinds) { [ ExerciseSection::CodeReview, ExerciseSection::Pattern ] }
  let(:rungs) { kinds.index_with { "junior" } }

  def annotate(check, mode, gotcha: nil) = generation_retention_annotation.call(check, kinds, "ruby_rails", mode, rungs, gotcha: gotcha)

  it "names code_review as a host on a day it can take the check" do
    expect(annotate(check, :application_code)).to eq("memoization (code_review or pattern)")
  end

  it "names no bug_hunt code_review, which never carries a retention check" do
    expect(annotate(check, :bug_hunt, gotcha: BugHuntGotchas.for_language("ruby_rails").first)).to eq("memoization (pattern)")
  end

  it "names no host for the concept of the day's trap" do
    expect(annotate(check, :bug_hunt, gotcha: BugHuntGotchas.find("rb_memo_falsy"))).to be_nil
  end

  it "names a host only at a rung whose vocabulary offers the concept" do
    comparison = [ ExerciseSection::DesignComparison ]
    tradeoff = ConceptMastery.new(concept: "denormalization_tradeoffs", language: "ruby_rails")
    annotate_at = ->(rung) { generation_retention_annotation.call(tradeoff, comparison, "ruby_rails", :application_code, { comparison.first => rung }) }

    expect(annotate_at.call("principal_engineer")).to eq("denormalization_tradeoffs (design_comparison)")
    expect(annotate_at.call("senior")).to be_nil
  end

  it "names no host whose bucket records the check under another language" do
    expect(annotate(ConceptMastery.new(concept: "memoization", language: "javascript"), :application_code)).to be_nil
  end
end
