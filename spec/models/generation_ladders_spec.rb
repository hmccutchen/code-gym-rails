require "rails_helper"

RSpec.describe GenerationLadders do
  it "loads each kind's rungs at its level for the day's mode and retains their owners" do
    ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails",
                             ladder_junior: "j", ladder_mid_level: "m", ladder_senior: "s", ladder_principal_engineer: "p")
    schema_concept = ConceptVocabulary::DATA_MODELING_CONCEPTS.first
    ConceptReference.create!(concept: schema_concept, language: "ruby_rails",
                             ladder_junior: "j2", ladder_mid_level: "m", ladder_senior: "s2", ladder_principal_engineer: "p2")
    rungs = { ExerciseSection::CodeReview => "senior", ExerciseSection::Challenge => "senior" }

    ladders = described_class.for(rungs, "ruby_rails", :schema_review)

    expect(ladders.keys).to eq(rungs.keys)
    expect(ladders.fetch(ExerciseSection::CodeReview)).to include(schema_concept => "s2")
    expect(ladders.fetch(ExerciseSection::CodeReview)).not_to have_key("n_plus_one")
    expect(ladders.fetch(ExerciseSection::Challenge)).to include("n_plus_one" => "s", schema_concept => "s2")
  end

  it "leaves the week's featured concept out of a kind that hides its concept, and keeps it for a kind that shows it" do
    hidden, shown = ConceptVocabulary::PLAN_REVIEW_CONCEPTS.first(2)
    [ [ hidden, "plan_review" ], [ shown, "plan_review" ], [ "n_plus_one", "ruby_rails" ] ].each do |concept, bucket|
      ConceptReference.create!(concept: concept, language: bucket,
                               ladder_junior: "j", ladder_mid_level: "m", ladder_senior: "s", ladder_principal_engineer: "p")
    end
    rungs = { ExerciseSection::PlanReview => "senior", ExerciseSection::Challenge => "senior" }
    featured = hidden

    plain = described_class.for(rungs, "ruby_rails", :application_code)
    withheld = described_class.for(rungs, "ruby_rails", :application_code, featured_concept: featured)

    expect(plain.fetch(ExerciseSection::PlanReview)).to include(hidden => "s", shown => "s")
    expect(withheld.fetch(ExerciseSection::PlanReview)).to include(shown => "s")
    expect(withheld.fetch(ExerciseSection::PlanReview)).not_to have_key(hidden)
    expect([ plain, withheld ].map { |ladders| ladders.fetch(ExerciseSection::Challenge) }).to all(include("n_plus_one" => "s"))
  end

  it "skips a row with no ladder and truncates a rung on read" do
    ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails",
                             ladder_junior: "x" * 500, ladder_mid_level: "m", ladder_senior: "s", ladder_principal_engineer: "p")
    ConceptReference.create!(concept: "caching", language: "ruby_rails", ladder_junior: "j")
    rungs = described_class.for({ ExerciseSection::CodeReview => "junior" }, "ruby_rails", :application_code).fetch(ExerciseSection::CodeReview)

    expect(rungs.fetch("n_plus_one").length).to eq(ConceptReference::MAX_LADDER_RUNG_LENGTH)
    expect(rungs).not_to have_key("caching")
  end

  describe "effective bug-hunt ladders" do
    let(:bug) { ExerciseSection::CodeReview }
    let(:challenge) { ExerciseSection::Challenge }
    let(:principal) { "principal_engineer" }
    let(:gotcha) { BugHuntGotchas.find("rb_delete_while_each") }
    let(:rungs) { { bug => principal, challenge => principal } }
    let(:reference) do
      ConceptReference.create!(concept: gotcha.concept, language: "ruby_rails",
        ladder_junior: "Find the visible removal during iteration.", ladder_mid_level: "Trace consecutive elements.",
        ladder_senior: "Account for adjacent even elements being skipped during traversal.",
        ladder_principal_engineer: "Weigh mutation against copying across service boundaries and their allocation costs.")
    end

    def render_ladders(ladders, only: nil)
      user = User.new(email: "ladder-render@example.com", skill_level: principal, focus_areas: [])
      render_generation_prompt(user, difficulty: KindDifficulty.new(levels: rungs.transform_keys(&:key), locked: []),
        ladders: ladders, only: only, code_review_mode: :bug_hunt, code_review_gotcha: gotcha,
        daily_kinds: rungs.keys, rotation: ExerciseSection.optional_slots(daily: rungs.keys).keys.index_with { nil })
    end

    it "labels the ladder owner alongside mixed senior-equivalent and principal baselines" do
      reference
      text = render_ladders(described_class.for(rungs, "ruby_rails", :bug_hunt, gotcha: gotcha))

      expect(text).to include("Concept ladders for code_review:\n- #{gotcha.concept}:")
      expect(text).to include("Baseline: #{KindDifficulty::LEVEL_DEFINITIONS.fetch('senior')}",
                             "Baseline: #{KindDifficulty::LEVEL_DEFINITIONS.fetch(principal)}")
    end

    it "uses persisted senior text for principal bug hunts in full generation and retry, without moving the configured rung" do
      reference
      ladders = described_class.for(rungs, "ruby_rails", :bug_hunt, gotcha: gotcha)

      [ render_ladders(ladders), render_ladders(ladders, only: bug) ].each do |text|
        expect(text).to include(reference.ladder_senior, "Sections at #{principal}:")
        expect(text).not_to include(reference.ladder_principal_engineer)
      end
      expect(rungs).to eq(bug => principal, challenge => principal)
      expect(reference.reload.ladder_principal_engineer).to include("service boundaries")
    end

    it "keeps ordinary principal text and preserves distinct shared-concept guidance in both input orders" do
      reference
      ordinary = described_class.for(rungs, "ruby_rails", :application_code)
      expect(ordinary.values).to all(include(gotcha.concept => reference.ladder_principal_engineer))

      [ rungs, rungs.to_a.reverse.to_h ].each do |ordered|
        ladders = described_class.for(ordered, "ruby_rails", :bug_hunt)
        expect(ladders.fetch(bug)).to include(gotcha.concept => reference.ladder_senior)
        expect(ladders.fetch(challenge)).to include(gotcha.concept => reference.ladder_principal_engineer)
        text = GenerationPrompt::DifficultyGuidance.render(rungs: ordered, difficulty: KindDifficulty.none, ladders: ladders, mode: :bug_hunt)
        expect(text).to include(reference.ladder_senior, reference.ladder_principal_engineer)
        expect(text.scan("- #{gotcha.concept}:").size).to eq(2)
        expect(text).to include("Concept ladders for code_review:\n- #{gotcha.concept}: #{reference.ladder_senior}",
                               "Concept ladders for challenge:\n- #{gotcha.concept}: #{reference.ladder_principal_engineer}")
      end
    end

    it "preserves the picked-gotcha exclusion and omits guidance when references are absent" do
      expect(described_class.for(rungs, "ruby_rails", :bug_hunt, gotcha: gotcha).values).to all(be_empty)
      expect(render_ladders({})).not_to include("Concept ladders for")
      reference
      ladders = described_class.for(rungs, "ruby_rails", :bug_hunt, gotcha: gotcha)
      expect(ladders.fetch(bug)).to include(gotcha.concept => reference.ladder_senior)
      expect(ladders.fetch(challenge)).not_to have_key(gotcha.concept)
    end

    it "keeps picked-gotcha and challenge-only guidance under their actual owners at the same effective rung" do
      reference
      ConceptReference.create!(concept: "n_plus_one", language: "ruby_rails",
        ladder_junior: "j", ladder_mid_level: "m", ladder_senior: "Trace the repeated query.", ladder_principal_engineer: "p")
      placed = { bug => "senior", challenge => "senior" }
      ladders = described_class.for(placed, "ruby_rails", :bug_hunt, gotcha: gotcha)
      text = GenerationPrompt::DifficultyGuidance.render(rungs: placed, difficulty: KindDifficulty.none, ladders: ladders, mode: :bug_hunt)

      expect(ladders.fetch(bug).keys).to eq([ gotcha.concept ])
      expect(ladders.fetch(challenge).keys).to eq([ "n_plus_one" ])
      expect(text).to include("Concept ladders for code_review:\n- #{gotcha.concept}: #{reference.ladder_senior}",
                             "Concept ladders for challenge:\n- n_plus_one: Trace the repeated query.")
      expect(text).not_to include("Concept ladders for code_review, challenge:")
    end

    it "deduplicates ordinary guidance only for the actual owners of each concept and text" do
      ladders = {
        bug => { "n_plus_one" => "Shared query guidance.", "memoization" => "Review cache behavior.",
                 "caching" => "Review-specific guidance." },
        challenge => { "n_plus_one" => "Shared query guidance.", "guard_clauses" => "Implement early returns.",
                       "caching" => "Challenge-specific guidance." }
      }
      [ [ bug, challenge ], [ challenge, bug ] ].each do |kinds|
        text = GenerationPrompt::DifficultyGuidance.render(rungs: kinds.index_with { "senior" },
          difficulty: KindDifficulty.none, ladders: ladders, mode: :application_code)
        groups = text.scan(/Concept ladders for ([^\n]+):\n((?:- [^\n]+\n?)+)/).to_h

        expect(groups.fetch(kinds.map(&:key).join(", "))).to eq("- n_plus_one: Shared query guidance.\n")
        expect(groups.fetch("code_review")).to eq("- caching: Review-specific guidance.\n- memoization: Review cache behavior.\n")
        expect(groups.fetch("challenge")).to eq("- caching: Challenge-specific guidance.\n- guard_clauses: Implement early returns.\n")
        expect(text.scan("- n_plus_one: Shared query guidance.").size).to eq(1)
      end
    end
  end
end
