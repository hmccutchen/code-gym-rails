require "rails_helper"

RSpec.describe "The answer key each discovery kind plants" do
  let(:long) { "x" * (PlantedKey::MAX_LENGTH + 20) }

  def cleaned(kind, key, section = {})
    section = section.merge(PlantedKey::FIELD => key)
    kind.reject_unusable!(section)
    section
  end

  {
    ExerciseSection::CodeReview     => %w[issue why_it_matters fix],
    ExerciseSection::SecurityReview => %w[vulnerability exploit mitigation]
  }.each do |kind, fields|
    describe kind do
      let(:usable) { fields.index_with { |field| "  #{field} text " } }

      it "keeps a usable key, cleaned" do
        expect(cleaned(kind, usable)[PlantedKey::FIELD]).to eq(fields.index_with { |field| "#{field} text" })
      end

      it "bounds an over-long field" do
        expect(cleaned(kind, usable.merge(fields.first => long))[PlantedKey::FIELD][fields.first].length).to eq(PlantedKey::MAX_LENGTH)
      end

      it "drops the key and keeps the section when a field is missing, blank or the wrong type" do
        rows = fields.map { |field| usable.except(field) } +
               [ usable.merge(fields.last => " "), usable.merge(fields.first => [ "a" ]), "not a hash", nil ]

        rows.each do |key|
          section = cleaned(kind, key, "snippet" => "code")
          expect(section).to eq("snippet" => "code"), "kept #{key.inspect}"
        end
      end
    end
  end

  describe ExerciseSection::PlanReview do
    let(:kind) { ExerciseSection::PlanReview }
    let(:flaw) { { "category" => "scope_creep", "flaw" => " Adds `export to CSV` ", "pushback" => "Split it out." } }

    it "keeps usable flaws, cleaned, up to the cap" do
      key = cleaned(kind, { "flaws" => [ flaw ] * (kind::MAX_PLANTED_FLAWS + 2) })[PlantedKey::FIELD]

      expect(key["flaws"].size).to eq(kind::MAX_PLANTED_FLAWS)
      expect(key["flaws"].first).to eq("category" => "scope_creep", "flaw" => "Adds `export to CSV`", "pushback" => "Split it out.")
    end

    it "drops an unknown category but keeps the flaw" do
      key = cleaned(kind, { "flaws" => [ flaw.merge("category" => "vibes") ] })[PlantedKey::FIELD]

      expect(key["flaws"]).to eq([ { "flaw" => "Adds `export to CSV`", "pushback" => "Split it out." } ])
    end

    it "drops a flaw missing its text or pushback, and the key when no flaw survives" do
      partial = { "flaws" => [ flaw.except("pushback"), flaw ] }
      expect(cleaned(kind, partial)[PlantedKey::FIELD]["flaws"].size).to eq(1)

      [ { "flaws" => [ flaw.except("flaw") ] }, { "flaws" => [] }, { "flaws" => "one" }, [ flaw ], nil ].each do |key|
        expect(cleaned(kind, key, "plan_excerpt" => "plan")).to eq("plan_excerpt" => "plan"), "kept #{key.inspect}"
      end
    end
  end

  describe ExerciseSection::PseudocodeToCode do
    let(:kind) { ExerciseSection::PseudocodeToCode }
    let(:section) { { "problem_statement" => "Sum the totals." } }

    it "keeps up to the cap of usable requirements, cleaned, alongside the problem statement" do
      key = { "missable_requirements" => [ " An empty list sums to zero. ", 7, "", "b", "c", "d" ] }

      expect(cleaned(kind, key, section)[PlantedKey::FIELD])
        .to eq("missable_requirements" => [ "An empty list sums to zero.", "b", "c" ])
    end

    it "drops the key and keeps the section when no requirement survives" do
      [ { "missable_requirements" => [] }, { "missable_requirements" => [ " " ] }, "list", nil ].each do |key|
        expect(cleaned(kind, key, section)).to eq(section), "kept #{key.inspect}"
      end
    end

    it "still refuses a section with no problem statement" do
      expect { cleaned(kind, { "missable_requirements" => [ "a" ] }) }.to raise_error(ProviderError::InvalidResponseError)
    end
  end

  it "gives each of the four kinds the answer_key field, and marks only them as planting a key" do
    planted = [ ExerciseSection::CodeReview, ExerciseSection::SecurityReview, ExerciseSection::PlanReview, ExerciseSection::PseudocodeToCode ]

    expect(ExerciseSection.all.select(&:planted_key?)).to match_array(planted)
    expect(planted.map(&:answer_key_fields)).to all(eq([ PlantedKey::FIELD ]))
  end
end
