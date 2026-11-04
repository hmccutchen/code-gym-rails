require "rails_helper"

RSpec.describe GenerationLadders do
  it "loads each kind's rungs at its level for the day's mode and merges them by level" do
    ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails",
                             ladder_junior: "j", ladder_mid_level: "m", ladder_senior: "s", ladder_principal_engineer: "p")
    schema_concept = ConceptVocabulary::DATA_MODELING_CONCEPTS.first
    ConceptReference.create!(concept: schema_concept, language: "ruby_rails",
                             ladder_junior: "j2", ladder_mid_level: "m", ladder_senior: "s2", ladder_principal_engineer: "p2")
    rungs = { ExerciseSection::CodeReview => "senior", ExerciseSection::Challenge => "senior" }

    ladders = described_class.for(rungs, "ruby_rails", :schema_review)

    expect(ladders.keys).to eq([ "senior" ])
    expect(ladders["senior"]).to include("n_plus_one" => "s", schema_concept => "s2")
  end

  it "leaves the week's featured concept out of a kind that hides its concept, and keeps it for a kind that shows it" do
    hidden, shown = ConceptVocabulary::PLAN_REVIEW_CONCEPTS.first(2)
    [ [ hidden, "plan_review" ], [ shown, "plan_review" ], [ "n_plus_one", "ruby_rails" ] ].each do |concept, bucket|
      ConceptReference.create!(concept: concept, language: bucket,
                               ladder_junior: "j", ladder_mid_level: "m", ladder_senior: "s", ladder_principal_engineer: "p")
    end
    rungs = { ExerciseSection::PlanReview => "senior", ExerciseSection::Challenge => "senior" }
    featured = FeaturedConcept.new(concept: hidden, bucket: "plan_review")

    plain = described_class.for(rungs, "ruby_rails", :application_code)
    withheld = described_class.for(rungs, "ruby_rails", :application_code, featured: featured)

    expect(plain["senior"]).to include(hidden => "s", shown => "s", "n_plus_one" => "s")
    expect(withheld["senior"]).to include(shown => "s", "n_plus_one" => "s")
    expect(withheld["senior"]).not_to have_key(hidden)
  end

  it "skips a row with no ladder and truncates a rung on read" do
    ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails",
                             ladder_junior: "x" * 500, ladder_mid_level: "m", ladder_senior: "s", ladder_principal_engineer: "p")
    ConceptReference.create!(concept: "caching", language: "ruby_rails", ladder_junior: "j")
    rungs = described_class.for({ ExerciseSection::CodeReview => "junior" }, "ruby_rails", :application_code)["junior"]

    expect(rungs.fetch("n_plus_one").length).to eq(ConceptReference::MAX_LADDER_RUNG_LENGTH)
    expect(rungs).not_to have_key("caching")
  end
end
