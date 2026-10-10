require "rails_helper"
require Rails.root.join("script/forced_concept_drafts")

# Fixtures for a concept in no vocabulary yet; see docs/proportionality-concept-2026-10-07.md.
RSpec.describe "proportionality judge fixtures" do
  concept = "proportionality"
  kind    = ExerciseSection::DesignComparison
  paths   = Dir[Rails.root.join("spec/fixtures/judge/design_comparison_#{concept}_*.json")].sort
  fixtures = paths.to_h { |path| [ File.basename(path, ".json"), JSON.parse(File.read(path)) ] }

  excluded_words = /\b(concurren\w*|race|races|racing|lock\w*|mutex\w*|threads?|atomic\w*|transactions?)\b/
  excluded_concepts = ConceptVocabulary::META_SKILL_CONCEPTS + ConceptVocabulary::SILENT_CORRECTNESS_CONCEPTS +
                      %w[concurrency transaction_safety idempotency]

  def self.text_of(fixture)
    fixture["section"].values_at("title", "scenario", "question", "piece_a", "piece_b").join("\n").downcase
  end

  it "has two fixtures at every rung" do
    expect(fixtures.values.map { |fixture| fixture["rung"] }.tally).to eq(KindDifficulty::LEVELS.index_with(2))
  end

  it "never reuses a scenario or a title" do
    %w[scenario title].each do |field|
      values = fixtures.values.map { |fixture| fixture.dig("section", field) }
      expect(values.uniq.size).to eq(values.size), field
    end
  end

  it "puts the better piece in both positions" do
    expect(fixtures.values.map { |fixture| fixture["expected_better"] }.uniq).to match_array(kind::PIECES)
  end

  fixtures.each do |name, fixture|
    describe name do
      let(:section) { fixture["section"] }

      it "has the shape of the existing design comparison fixtures" do
        reference = JSON.parse(File.read(Rails.root.join("spec/fixtures/judge/design_comparison_senior_valid.json")))

        expect(fixture.keys).to match_array(reference.keys)
        expect(section.keys).to match_array(reference["section"].keys)
        expect(fixture).to include("kind" => kind.key, "locked" => false, "principle" => nil)
        expect(kind::PIECES).to include(fixture["expected_better"])
        expect(section["concept"]).to eq(concept)
      end

      it "expects the judge to keep it, an edit allowed only at principal_engineer" do
        expected = fixture["rung"] == "principal_engineer" ? "keep_or_edit" : "keep"
        expect(fixture["expected"]).to eq(expected)
      end

      it "has two pieces of valid Ruby that ingest would not refuse for length" do
        %w[piece_a piece_b].each do |field|
          expect(Prism.parse(section[field])).to be_success, field
          expect(section[field].lines.count { |line| line.strip.present? }).to be <= kind::MAX_PIECE_LINES
        end
      end

      it "carries no answer key, as a section the judge sees never does" do
        expect(section.keys & ExerciseSection.all_answer_key_fields).to be_empty
      end

      it "names no excluded subject or concept" do
        text = self.class.text_of(fixture)

        expect(text).not_to match(excluded_words)
        excluded_concepts.each do |excluded|
          expect(text).not_to include(excluded)
          expect(text).not_to include(excluded.tr("_", " "))
        end
      end
    end
  end

  # The concept joins no vocabulary, hosting list or prompt until the judge comparison has been read.
  it "is in no vocabulary and no design comparison hosting list" do
    ConceptVocabulary.languages.each { |language| expect(ConceptVocabulary.for_language(language)).not_to include(concept) }
    expect(kind.hosted_concepts).not_to include(concept)
    %w[ruby_rails javascript].each do |language|
      ExerciseSection.all.each do |each_kind|
        expect(ConceptVocabulary.selectable_for_section(each_kind.key, language, rung: "principal_engineer"))
          .not_to include(concept)
      end
    end
  end

  it "has a draft guidance line in its design note, which no prompt reads" do
    line = ForcedConceptDrafts.guidance_for(concept)

    expect(line).to start_with("- The proportionality concept")
    expect(Rails.root.glob("app/**/*.rb").map(&:read).join).not_to include(line)
  end
end
