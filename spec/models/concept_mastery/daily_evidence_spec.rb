require "rails_helper"

RSpec.describe ConceptMastery::DailyEvidence do
  let(:user) { User.create!(email: "daily-evidence@example.com") }
  let(:exercise) do
    user.daily_exercises.create!(date: Date.current, generated_at: Time.current, language: "ruby_rails",
      problem_set: %w[code_review pattern challenge].index_with { {} })
  end
  let(:response) do
    user.daily_responses.create!(date: exercise.date, daily_exercise: exercise, submitted_at: Time.current,
      answers: %w[code_review pattern challenge architecture].index_with { "An answer" },
      concept_tags: { "code_review" => "n_plus_one", "pattern" => "n_plus_one",
        "challenge" => "n_plus_one", "architecture" => "caching" },
      section_ratings: { "code_review" => "right_level", "pattern" => "too_hard" },
      ai_review: { "code_review" => { "rating" => "strong" }, "pattern" => { "rating" => "developing" } })
  end

  it "collects eligible same-identity occurrences and only retryable answered siblings" do
    evidence = described_class.for(response, accepted_sections: %w[code_review pattern], legacy_sections: [])
    expect(evidence.size).to eq(1)
    expect(evidence.first).to have_attributes(concept: "n_plus_one", bucket: "ruby_rails",
      sections: { "code_review" => { "rating" => "strong", "self_rating" => "right_level" },
        "pattern" => { "rating" => "developing", "self_rating" => "too_hard" } },
      pending_sections: %w[challenge])
  end

  it "excludes invalid grades, legacy keys, skipped answers, bug hunts and retired tags" do
    response.ai_review["challenge"] = { "rating" => "invalid" }
    response.answers["pattern"] = ""
    exercise.problem_set["code_review"]["purpose"] = "Find a trap"
    expect(described_class.for(response, accepted_sections: response.ai_review.keys, legacy_sections: [])).to eq([])
    exercise.problem_set["code_review"].delete("purpose")
    expect(described_class.for(response, accepted_sections: response.ai_review.keys, legacy_sections: %w[code_review])).to eq([])
    response.concept_tags["code_review"] = "retired_tag"
    expect(described_class.for(response, accepted_sections: response.ai_review.keys, legacy_sections: [])).to eq([])
  end

  it "keeps historical missing self-ratings nil and stored invalid siblings terminal" do
    response.section_ratings = {}
    response.ai_review["pattern"] = { "rating" => "invalid" }
    response.answers["challenge"] = ""
    evidence = described_class.for(response, accepted_sections: response.ai_review.keys, legacy_sections: [])
    expect(evidence.first.sections).to eq("code_review" => { "rating" => "strong", "self_rating" => nil })
    expect(evidence.first.pending_sections).to eq([])
  end

  it "keeps identical names in different bucket identities separate" do
    common = "n_plus_one"
    allow(ConceptBucket).to receive(:vocabulary_for).and_call_original
    allow(ConceptBucket).to receive(:vocabulary_for).with("architecture").and_return([ common ])
    exercise.update!(problem_set: { "pattern" => {}, "architecture" => {} })
    response.answers = { "pattern" => "Answer", "architecture" => "Answer" }
    response.concept_tags = { "pattern" => common, "architecture" => common }
    response.ai_review = { "pattern" => { "rating" => "strong" }, "architecture" => { "rating" => "solid" } }
    evidence = described_class.for(response, accepted_sections: response.ai_review.keys, legacy_sections: [])
    expect(evidence.map(&:bucket)).to contain_exactly("ruby_rails", "architecture")
    expect(evidence.map(&:sections).map(&:size)).to eq([ 1, 1 ])
  end
end
