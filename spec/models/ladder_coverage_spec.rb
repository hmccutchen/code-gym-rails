require "rails_helper"

RSpec.describe LadderCoverage do
  let(:user) { User.create!(email: "coverage@example.com", name: "Coverage", language: "ruby_rails") }

  def laddered(concept, bucket)
    ConceptReference.create!(concept: concept, language: bucket,
                             ladder_junior: "j", ladder_senior: "s", ladder_principal_engineer: "p")
  end

  it "has an entry for every section kind, targeted or not" do
    coverage = described_class.for(user)

    ExerciseSection.all.each { |kind| expect(coverage.for_kind(kind)).to be_present }
  end

  # Coverage asks whether a kind can ever be offered a concept, so it spans every code_review mode.
  it "covers code_review across every mode" do
    pairs = described_class.for(user).for_kind(ExerciseSection::CodeReview).pairs.map(&:first)

    DailyPlan::CODE_REVIEW_MODE_WEIGHTS.each_key do |mode|
      expect(pairs).to include(*ConceptVocabulary.selectable_for_section("code_review", "ruby_rails", mode: mode))
    end
  end

  it "reads a targeted kind's pairs at its target level" do
    pairs = ->(level) do
      user.update!(section_kind_levels: { "design_comparison" => level })
      described_class.for(user.reload).for_kind(ExerciseSection::DesignComparison).pairs.map(&:first)
    end

    expect(pairs.call("principal_engineer")).to include("denormalization_tradeoffs")
    expect(pairs.call("senior")).not_to include("denormalization_tradeoffs")
  end

  it "counts a laddered row as grounded and both a missing and a ladderless row as gaps" do
    laddered("n_plus_one", "ruby_rails")
    ConceptReference.create!(concept: "caching", language: "ruby_rails", tagline: "no ladder")

    entry = described_class.for(user).for_kind(ExerciseSection::Challenge)

    expect(entry.grounded).to include([ "n_plus_one", "ruby_rails" ])
    expect(entry.gaps).to include([ "caching", "ruby_rails" ])
    expect(entry.gaps).not_to include([ "n_plus_one", "ruby_rails" ])
    expect(entry.pairs.size).to eq(entry.grounded.size + entry.gaps.size)
  end

  it "counts both languages for a mixed user" do
    user.update!(language: "mixed")

    buckets = described_class.for(user).for_kind(ExerciseSection::Challenge).pairs.map(&:last).uniq

    expect(buckets).to match_array(DailyExercise::LANGUAGES)
  end

  it "records a language-independent kind under its own bucket" do
    buckets = described_class.for(user).for_kind(ExerciseSection::Architecture).pairs.map(&:last).uniq

    expect(buckets).to eq([ ConceptBucket::ARCHITECTURE ])
  end

  it "deduplicates gaps shared by several kinds" do
    gaps = described_class.for(user).gaps_for([ ExerciseSection::CodeReview, ExerciseSection::Pattern ])

    expect(gaps).to eq(gaps.uniq)
  end

  it "names the targeted kinds a concept grounds" do
    coverage = described_class.for(user)
    kinds = [ ExerciseSection::Challenge, ExerciseSection::Architecture ]

    expect(coverage.grounding_kinds(kinds, "n_plus_one", "ruby_rails")).to eq([ ExerciseSection::Challenge ])
  end

  it "reads references in one query" do
    queries = []
    callback = ->(*, payload) { queries << payload[:sql] if payload[:sql].include?("concept_references") }

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { described_class.for(user) }

    expect(queries.size).to eq(1)
  end
end
