require "rails_helper"

RSpec.describe "The answer key each discovery kind plants" do
  let(:long) { "x" * (PlantedKey::MAX_LENGTH + 20) }

  def cleaned(kind, key, section = {})
    section = section.merge(PlantedKey::FIELD => key)
    PlantedKey.store!(section, kind.normalize_planted_key(section))
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

      it "keeps an over-long field whole, for ingest to drop the key as too long rather than cut it" do
        expect(kind.normalize_planted_key(PlantedKey::FIELD => usable.merge(fields.first => long))[fields.first]).to eq(long)
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
      expect { kind.reject_unusable!({ PlantedKey::FIELD => { "missable_requirements" => [ "a" ] } }) }
        .to raise_error(ProviderError::InvalidResponseError)
    end
  end

  describe ".quote_tally" do
    def unquoted(kind, section) = kind.quote_tally(section, language: "ruby_rails").unresolved

    it "checks a code review's issue against its snippet and any current schema" do
      kind = ExerciseSection::CodeReview
      section = { "snippet" => "orders.each do |order|\n  order.customer.name\nend", "current_schema" => "t.bigint :customer_id",
                  PlantedKey::FIELD => { "issue" => "`order.customer.name` per row, with no index on `t.bigint :customer_id`" } }

      expect(unquoted(kind, section)).to eq([])
      expect(unquoted(kind, section.merge(PlantedKey::FIELD => { "issue" => "`order.user` per row" }))).to eq([ "order.user" ])
      expect(unquoted(kind, section.merge(PlantedKey::FIELD => { "issue" => "A query per row." })).size).to eq(1)
    end

    it "checks a security review's vulnerability against its snippet" do
      kind = ExerciseSection::SecurityReview
      section = { "snippet" => "User.where(\"name = '\#{name}'\")", PlantedKey::FIELD => { "vulnerability" => "`User.where(\"name = '\#{name}'\")` interpolates input" } }

      expect(unquoted(kind, section)).to eq([])
      expect(unquoted(kind, section.merge("snippet" => "User.find(id)")).size).to eq(1)
    end

    it "checks each plan review flaw against the plan, and counts a flaw with no quote" do
      kind = ExerciseSection::PlanReview
      flaws = [ { "flaw" => "`exactly 300 seconds` has no reason" }, { "flaw" => "Scope grew." }, { "flaw" => "`never written`" } ]
      section = { "plan_excerpt" => "Cache it for exactly 300\nseconds.", PlantedKey::FIELD => { "flaws" => flaws } }

      expect(unquoted(kind, section)).to eq([ "Scope grew.", "never written" ])
    end

    it "reads the section's scenario after its code, for every keyed kind" do
      kind = ExerciseSection::SecurityReview
      section = { "snippet" => "User.find(id)", "scenario" => "Admins sign in through `SsoGateway`.",
                  PlantedKey::FIELD => { "vulnerability" => "`User.find(id)` trusts `SsoGateway`" } }

      expect(kind.quote_tally(section, language: "ruby_rails").counts).to eq(verbatim: 1, reference: 0, scenario: 1, unresolved: 0)
    end

    it "quotes nothing for pseudocode to code, so nothing is unquoted" do
      expect(unquoted(ExerciseSection::PseudocodeToCode, PlantedKey::FIELD => { "missable_requirements" => [ "Empty input." ] })).to eq([])
    end
  end

  describe "every kind that plants a key" do
    let(:planted) { ExerciseSection.all.select(&:planted_key?) }

    it "answers every key hook, so a new keyed kind fails here before ingest" do
      planted.each do |kind|
        section = FakeService::EXERCISE_PROBLEM_SET.fetch(kind.key).deep_dup
        expect(kind.normalize_planted_key(section)).to be_a(Hash), kind.key
        expect(kind.quote_tally(section, language: "ruby_rails").unresolved).to eq([]), kind.key
        expect(kind.key_context_fields).to all(be_a(String)), kind.key
      end
    end

    it "keeps every section through ingest whatever junk its key holds, and notes the key missing" do
      [ "a string", [ 1 ], 7, nil, { "unknown" => "field" } ].each do |junk|
        planted.each do |kind|
          section = FakeService::EXERCISE_PROBLEM_SET.fetch(kind.key).deep_dup.merge("answer_key" => junk)
          result = ProblemSetIngest.call({ kind.key => section }, language: "ruby_rails", daily: DailyKinds::DEFAULT,
                                         expected_keys: [ kind.key ])

          expect(result.problem_set).to have_key(kind.key), "#{kind.key} dropped over #{junk.inspect}"
          expect(result.key_notes.map(&:outcome)).to eq([ "missing" ]), "#{kind.key} with #{junk.inspect}"
        end
      end
    end

    it "shows the key sheet only fields the section really has" do
      planted.each do |kind|
        section = FakeService::EXERCISE_PROBLEM_SET.fetch(kind.key)
        expect(section.slice(*kind.key_context_fields)).not_to be_empty, kind.key
      end
    end
  end

  it "gives each of the four kinds the answer_key field, and marks only them as planting a key" do
    planted = [ ExerciseSection::CodeReview, ExerciseSection::SecurityReview, ExerciseSection::PlanReview, ExerciseSection::PseudocodeToCode ]

    expect(ExerciseSection.all.select(&:planted_key?)).to match_array(planted)
    expect(planted.map(&:answer_key_fields)).to all(eq([ PlantedKey::FIELD ]))
  end
end
