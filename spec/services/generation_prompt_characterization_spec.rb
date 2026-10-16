require "rails_helper"

# Rebaseline with UPDATE_PROMPT_SNAPSHOTS=1 only when a prompt change is the intended deliverable.
RSpec.describe "generation prompt characterization" do
  SNAPSHOT_DIR = Rails.root.join("spec/fixtures/prompt_snapshots").freeze

  # Unpersisted and explicit, so nothing here reads the database or the clock.
  let(:user) do
    User.new(
      email:       "snapshot@example.com",
      name:        "Snapshot",
      skill_level: "junior",
      focus_areas: []
    )
  end

  def render(language, third, fourth, mode)
    render_generation_prompt(
      user, language,
      third: third, fourth: fourth, code_review_mode: mode,
      reinforcement: [], due_checks: [], established: [], history: [],
      fourth_reinforcement: [], fourth_due_checks: [], fourth_established: []
    )
  end

  def snapshot_path(language, third, fourth, mode)
    SNAPSHOT_DIR.join("#{language}__#{third}__#{fourth}__#{mode}.txt")
  end

  DailyExercise::LANGUAGES.each do |language|
    ExerciseSection.thirds.map { |kind| kind.key.to_sym }.each do |third|
      ExerciseSection.fourths.map { |kind| kind.key.to_sym }.each do |fourth|
        DailyPlan::CODE_REVIEW_MODE_WEIGHTS.each_key do |mode|
          context "#{language} / #{third} / #{fourth} / #{mode}" do
            let(:prompt) { render(language, third, fourth, mode) }
            let(:path)   { snapshot_path(language, third, fourth, mode) }

            it "renders every section this combination presents" do
              expect(prompt).to include(*%W[code_review pattern #{third} #{fourth}])
            end

            it "matches its recorded snapshot byte for byte" do
              if ENV["UPDATE_PROMPT_SNAPSHOTS"]
                FileUtils.mkdir_p(SNAPSHOT_DIR)
                File.write(path, prompt)
              end

              expect(path).to exist,
                "No snapshot at #{path.relative_path_from(Rails.root)}. " \
                "Record it against unmodified code with UPDATE_PROMPT_SNAPSHOTS=1."

              expect(prompt).to eq(File.read(path))
            end
          end
        end
      end
    end
  end

  BARE_PLAN = {
    pattern: nil, third: nil, fourth: nil,
    reinforcement: [], due_checks: [], established: [], history: [],
    fourth_reinforcement: [], fourth_due_checks: [], fourth_established: []
  }.freeze

  DEFAULT_OPTIONAL_SLOTS = ExerciseSection.optional_slots(daily: DailyKinds::DEFAULT)

  OPTIONAL_SLOT_CHOICES = DEFAULT_OPTIONAL_SLOTS.values.map do |kinds|
    [ nil, *kinds.map { |kind| kind.key.to_sym } ]
  end

  PLANNED_SHAPES = OPTIONAL_SLOT_CHOICES.first.product(*OPTIONAL_SLOT_CHOICES.drop(1))
    .map { |chosen| DEFAULT_OPTIONAL_SLOTS.keys.zip(chosen).to_h }
    .select { |slots| DailyKinds::COUNT + slots.values.compact.size <= ExerciseSection::MAX_SECTIONS }
    .freeze

  SHAPE_FIXTURES = DailyExercise::LANGUAGES.flat_map { |language|
    DailyPlan::CODE_REVIEW_MODE_WEIGHTS.each_key.flat_map { |mode|
      PLANNED_SHAPES.map do |slots|
        name = [ "shape", language, mode, *slots.values_at(:pattern, :third, :fourth).map { |kind| kind || "none" } ].join("__")
        [ name, { language: language, mode: mode, slots: slots } ]
      end
    }
  }.to_h.freeze

  CURATED_METHOD = RealSource::APPLICATION_CODE.find { |excerpt| excerpt.id == "app/services/ai_service.rb#annotate_retention_concept" }

  CURATED_MIGRATION = RealSource::SCHEMA_REVIEW.first

  SNAPSHOT_HISTORY = [
    { date: "2026-10-14",
      concepts: { "code_review" => "n_plus_one", "design_comparison" => "memoization", "pattern" => "memoization", "challenge" => "" },
      scenarios: [ "inventory restocking service", "ticket queue" ], sections_answered: 3, sections_total: 4,
      self_ratings: { "code_review" => "too_hard", "design_comparison" => "right_level" },
      ai_ratings: { "code_review" => "developing", "design_comparison" => "solid" },
      answered_sections: %w[code_review design_comparison pattern] },
    { date: "2026-10-13",
      concepts: { "code_review" => "transaction_safety", "pattern" => "caching" },
      scenarios: [ "parking meter" ], sections_answered: 1, sections_total: 2,
      self_ratings: { "code_review" => "right_level" }, ai_ratings: { "code_review" => "solid" },
      answered_sections: %w[code_review] },
    { date: "2026-10-10",
      concepts: { "code_review" => "memoization" }, sections_answered: 1, sections_total: 3,
      self_ratings: {}, ai_ratings: {} }
  ].freeze

  MIXED_LOCKS = KindDifficulty.new(
    levels: { "code_review" => "senior", "challenge" => "senior", "pattern" => "mid_level" },
    locked: %w[code_review challenge design_comparison]
  )

  LADDERS = {
    "senior"    => { "n_plus_one" => "a senior n_plus_one rung", "memoization" => "a senior memoization rung" },
    "mid_level" => { "n_plus_one" => "a mid_level n_plus_one rung" }
  }.freeze

  # Each entry renders through the one builder with explicit inputs and pins the lines those inputs must produce.
  CASE_FIXTURES = {
    "case__ruby_rails__established" => {
      render:   -> { render_case("ruby_rails", pattern: :pattern, third: :challenge,
                                 established: [ mastery("memoization", "ruby_rails"), mastery("scope_chaining", "ruby_rails") ]) },
      includes: [ "Established concepts (well past first mastery — survived a retention check): memoization, scope_chaining" ],
      excludes: [ "Established fourth-section concept" ]
    },
    "case__ruby_rails__fourth_established" => {
      render:   -> { render_case("ruby_rails", third: :challenge, fourth: :pseudocode_to_code,
                                 fourth_established: [ mastery("missing_base_case", "pseudocode_to_code") ]) },
      includes: [ "Established fourth-section concept (well past first mastery, survived a retention check): missing_base_case" ],
      excludes: [ "Established concepts (well past" ]
    },
    "case__ruby_rails__retention_mixed_hosts" => {
      render:   -> { render_case("ruby_rails", pattern: :pattern, third: :challenge,
                                 due_checks: [ mastery("memoization", "ruby_rails"), mastery("service_boundaries", "architecture") ]) },
      includes: [ "Retention checks due today: memoization (code_review, design_comparison, pattern, or challenge)" ],
      excludes: [ "service_boundaries" ]
    },
    "case__ruby_rails__retention_unhosted" => {
      render:   -> { render_case("ruby_rails", pattern: :pattern, third: :challenge,
                                 due_checks: [ mastery("service_boundaries", "architecture") ]) },
      includes: [],
      excludes: [ "Retention checks due today", "service_boundaries" ]
    },
    "case__ruby_rails__retention_schema_review_mode" => {
      render:   -> { render_case("ruby_rails", pattern: :pattern, code_review_mode: :schema_review,
                                 due_checks: [ mastery("missing_index", "ruby_rails"), mastery("memoization", "ruby_rails") ]) },
      includes: [ "Retention checks due today: missing_index (code_review, design_comparison, or pattern), memoization (design_comparison or pattern)" ],
      excludes: []
    },
    "case__ruby_rails__reinforcement_tiers" => {
      render:   -> { render_case("ruby_rails", pattern: :pattern, third: :challenge,
                                 reinforcement: [ { concept: "n_plus_one", bucket: "ruby_rails", tier: "reduced" },
                                                  { concept: "memoization", bucket: "ruby_rails", tier: "standard", drilled: true },
                                                  { concept: "callbacks_vs_service", bucket: "ruby_rails", tier: "reduced", drilled: true } ]) },
      includes: [ "Concepts needing reinforcement right now: n_plus_one (reduced), memoization (standard, drilled), callbacks_vs_service (reduced, drilled)" ],
      excludes: []
    },
    "case__ruby_rails__shared_concept" => {
      render:   -> { render_case("ruby_rails", shared_concept: "n_plus_one",
                                 reinforcement: [ { concept: "n_plus_one", bucket: "ruby_rails", tier: "reduced" } ]) },
      includes: [ "- The code_review and design_comparison sections share `n_plus_one` as their concept today." ],
      excludes: []
    },
    "case__ruby_rails__history" => {
      render:   -> { render_case("ruby_rails", pattern: :pattern, third: :challenge, history: SNAPSHOT_HISTORY) },
      includes: [ "2026-10-14: 3/4 answered | code_review→n_plus_one (self: too_hard, ai: developing), " \
                  "design_comparison→memoization (self: right_level, ai: solid), pattern→memoization (self: unrated, ai: unreviewed) " \
                  "| framings: inventory restocking service; ticket queue",
                  "2026-10-13: 1/2 answered | code_review→transaction_safety (self: right_level, ai: solid), " \
                  "pattern→caching (self: unrated, ai: skipped) | framings: parking meter",
                  "2026-10-10: 1/3 answered | code_review→memoization (self: unrated, ai: unreviewed)\n" ],
      excludes: [ "No history yet" ]
    },
    "case__ruby_rails__flavor_everyday" => {
      render:   -> { render_case("ruby_rails", pattern: :pattern, third: :challenge, scenario_flavor: :everyday) },
      includes: [ "everyday settings people already know from daily life", "Keep the setting's own words plain and familiar" ],
      excludes: [ "legacy GraphQL maintenance scenario" ]
    },
    "case__ruby_rails__profile_blank" => {
      render:   -> { render_case("ruby_rails", pattern: :pattern, third: :challenge, as: profile(name: "", skill_level: "junior", focus_areas: [])) },
      includes: [ "- Name: (not given)", "- Priority focus areas: general Ruby/Rails patterns" ],
      excludes: [ "<engineer_text>" ]
    },
    "case__ruby_rails__rungs_targeted" => {
      render:   -> { render_case("ruby_rails", pattern: :pattern, third: :challenge,
                                 difficulty: KindDifficulty.new(levels: { "design_comparison" => "principal_engineer", "pattern" => "mid_level" }, locked: []),
                                 due_checks: [ mastery("denormalization_tradeoffs", "ruby_rails") ]) },
      includes: [ "Sections at junior: code_review, challenge", "Sections at mid_level: pattern", "Sections at principal_engineer: design_comparison",
                  "Retention checks due today: denormalization_tradeoffs (design_comparison, pattern, or challenge)",
                  "Unlocked (code_review, design_comparison, pattern, challenge)" ],
      excludes: [ "Locked (" ]
    },
    "case__ruby_rails__locks_mixed_with_ladders" => {
      render:   -> { render_case("ruby_rails", pattern: :pattern, third: :challenge, difficulty: MIXED_LOCKS, ladders: LADDERS) },
      includes: [ "Sections at junior: design_comparison\nPitch these problems at this level. A junior problem is:",
                  "Sections at mid_level: pattern\nPitch these problems at this level for whichever concept you choose:\n- n_plus_one: a mid_level n_plus_one rung",
                  "Sections at senior: code_review, challenge", "- memoization: a senior memoization rung",
                  "Unlocked (design_comparison, pattern)", "Locked (code_review, challenge)" ],
      excludes: []
    },
    "case__ruby_rails__fourth_reinforcement" => {
      render:   -> { render_case("ruby_rails", third: :challenge, fourth: :plan_review,
                                 fourth_reinforcement: [ { concept: "scope_creep", bucket: "plan_review", tier: "standard" } ]) },
      includes: [ "Fourth-section (plan_review) concept needing reinforcement: scope_creep (standard)" ],
      excludes: [ "Retention check due for the fourth section" ]
    },
    "case__ruby_rails__fourth_due_check" => {
      render:   -> { render_case("ruby_rails", third: :challenge, fourth: :ambiguity_hunt,
                                 fourth_due_checks: [ mastery("undefined_scope_boundary", "ambiguity_hunt") ]) },
      includes: [ "Fourth-section (ambiguity_hunt) concept needing reinforcement: none",
                  "Retention check due for the fourth section today: undefined_scope_boundary (ambiguity_hunt bucket)." ],
      excludes: [ "Retention checks due today" ]
    },
    "case__ruby_rails__source_annotate_retention_concept" => {
      render:   -> { render_case("ruby_rails", pattern: :pattern, third: :challenge, code_review_source: CURATED_METHOD) },
      includes: [ "MODIFIED COPY of this real method from Code Gym's own source (`app/services/ai_service.rb#annotate_retention_concept`)",
                  "def annotate_retention_concept(cm, kinds, language, code_review_mode, rungs)" ],
      excludes: [ "must be realistic Ruby/Rails code" ]
    },
    "case__ruby_rails__source_migration" => {
      render:   -> { render_case("ruby_rails", pattern: :pattern, code_review_mode: :schema_review, code_review_source: CURATED_MIGRATION) },
      includes: [ "MODELLED ON this real one from Code Gym's own schema history (`#{CURATED_MIGRATION.id}`)",
                  "create_table :push_subscriptions", 'create_table "push_subscriptions"' ],
      excludes: [ "The code_review snippet must be a Rails migration" ]
    },
    "case__javascript__profile_populated" => {
      render:   -> { render_case("javascript", pattern: :pattern, third: :parsons_problem,
                                 as: profile(name: "Ada Lovelace", skill_level: "senior", focus_areas: %w[hooks closures])) },
      includes: [ "- Name: <engineer_text>Ada Lovelace</engineer_text>", "- Skill level: senior", "- Priority focus areas: hooks, closures",
                  "Sections at senior: code_review, design_comparison, pattern, parsons_problem" ],
      excludes: [ "Sections at junior" ]
    },
    "case__javascript__flavor_everyday" => {
      render:   -> { render_case("javascript", third: :architecture, fourth: :ambiguity_hunt, scenario_flavor: :everyday) },
      includes: [ "everyday settings people already know from daily life", "real TypeScript syntax and type annotations" ],
      excludes: [ "legacy GraphQL maintenance scenario" ]
    },
    "case__javascript__reinforcement_tiers" => {
      render:   -> { render_case("javascript", pattern: :pattern, fourth: :plan_review,
                                 reinforcement: [ { concept: "closures", bucket: "javascript", tier: "reduced" },
                                                  { concept: "generics", bucket: "javascript", tier: "standard", drilled: true } ]) },
      includes: [ "Concepts needing reinforcement right now: closures (reduced), generics (standard, drilled)" ],
      excludes: []
    },
    "case__javascript__retention_mixed_hosts" => {
      render:   -> { render_case("javascript", third: :security_review, fourth: :plan_review,
                                 due_checks: [ mastery("xss_prevention", "javascript"), mastery("service_boundaries", "architecture") ]) },
      includes: [ "Retention checks due today: xss_prevention (code_review or security_review)" ],
      excludes: [ "service_boundaries" ]
    },
    "case__retry__ruby_rails__code_review_schema_review" => {
      render:   -> { render_case("ruby_rails", pattern: :pattern, third: :challenge, fourth: :plan_review, code_review_mode: :schema_review,
                                 only: ExerciseSection::CodeReview, fixed_concept: "missing_index", shared_concept: "n_plus_one",
                                 reinforcement: [ { concept: "n_plus_one", bucket: "ruby_rails", tier: "reduced" } ],
                                 due_checks: [ mastery("missing_index", "ruby_rails"), mastery("memoization", "ruby_rails") ],
                                 established: [ mastery("scope_chaining", "ruby_rails") ],
                                 fourth_reinforcement: [ { concept: "scope_creep", bucket: "plan_review", tier: "standard" } ]) },
      includes: [ "This section's concept must be exactly `missing_index`", "Retention checks due today: missing_index (code_review)\n",
                  "Established concepts (well past first mastery — survived a retention check): scope_chaining",
                  "Fourth-section (plan_review) concept needing reinforcement: scope_creep (standard)", "Sections at junior: code_review\n" ],
      excludes: [ "as their concept today", "memoization (", '"pattern": {' ],
      schema:   %w[code_review]
    },
    "case__retry__ruby_rails__third_architecture" => {
      render:   -> { render_case("ruby_rails", pattern: :pattern, third: :architecture,
                                 only: ExerciseSection::Architecture, fixed_concept: "service_boundaries", shared_concept: "n_plus_one",
                                 reinforcement: [ { concept: "n_plus_one", bucket: "ruby_rails", tier: "reduced" } ],
                                 due_checks: [ mastery("service_boundaries", "architecture"), mastery("memoization", "ruby_rails") ],
                                 established: [ mastery("memoization", "ruby_rails") ]) },
      includes: [ "This section's concept must be exactly `service_boundaries`", "Retention checks due today: service_boundaries (architecture)\n",
                  "Sections at junior: architecture\n" ],
      excludes: [ "as their concept today", "memoization (", '"code_review": {' ],
      schema:   %w[architecture]
    },
    "case__retry__javascript__fourth_pseudocode_to_code" => {
      render:   -> { render_case("javascript", third: :challenge, fourth: :pseudocode_to_code,
                                 only: ExerciseSection::PseudocodeToCode, fixed_concept: "missing_base_case", shared_concept: "closures",
                                 reinforcement: [ { concept: "closures", bucket: "javascript", tier: "reduced" } ],
                                 due_checks: [ mastery("closures", "javascript") ], established: [ mastery("closures", "javascript") ],
                                 fourth_due_checks: [ mastery("missing_base_case", "pseudocode_to_code") ]) },
      includes: [ "This section's concept must be exactly `missing_base_case`",
                  "Fourth-section (pseudocode_to_code) concept needing reinforcement: none",
                  "Retention check due for the fourth section today: missing_base_case (pseudocode_to_code bucket).",
                  "Sections at junior: pseudocode_to_code\n" ],
      excludes: [ "as their concept today", "Retention checks due today", '"challenge": {' ],
      schema:   %w[pseudocode_to_code]
    }
  }.freeze

  def render_case(language, as: user, **plan)
    render_generation_prompt(as, language, **BARE_PLAN.merge(plan))
  end

  def mastery(concept, bucket)
    ConceptMastery.new(concept: concept, language: bucket)
  end

  def profile(name:, skill_level:, focus_areas:)
    User.new(email: "snapshot@example.com", name: name, skill_level: skill_level, focus_areas: focus_areas)
  end

  def schema_keys(prompt)
    schema = prompt[/Return JSON matching this schema exactly:\n(.*)\z/m, 1]
    expect(schema).not_to be_nil

    schema.scan(/^  "(\w+)": \{$/).flatten
  end

  def expect_snapshot(name, prompt)
    path = SNAPSHOT_DIR.join("#{name}.txt")
    File.write(path, prompt) if ENV["UPDATE_PROMPT_SNAPSHOTS"]

    expect(path).to exist,
      "No snapshot at #{path.relative_path_from(Rails.root)}. " \
      "Record it against unmodified code with UPDATE_PROMPT_SNAPSHOTS=1."

    expect(prompt).to eq(File.read(path))
  end

  describe "planned day shapes" do
    it "enumerates two-, three- and four-section days and nothing longer" do
      expect(PLANNED_SHAPES.map { |slots| slots.values.compact.size }.tally).to eq(0 => 1, 1 => 8, 2 => 19)
    end

    SHAPE_FIXTURES.each do |name, shape|
      context name do
        let(:slots)  { shape.fetch(:slots) }
        let(:prompt) { render_case(shape.fetch(:language), code_review_mode: shape.fetch(:mode), **slots) }

        it "lists exactly the planned kinds in the schema, fixed kinds first" do
          expected = [ "code_review", "design_comparison", slots[:pattern], slots[:third], slots[:fourth] ].compact.map(&:to_s)

          expect(expected.size).to be <= ExerciseSection::MAX_SECTIONS
          expect(schema_keys(prompt)).to eq(expected)
        end

        it "matches its recorded snapshot byte for byte" do
          expect_snapshot(name, prompt)
        end
      end
    end
  end

  describe "populated and retry cases" do
    CASE_FIXTURES.each do |name, fixture|
      context name do
        let(:prompt) { instance_exec(&fixture.fetch(:render)) }

        it "renders what its inputs call for" do
          fixture.fetch(:includes).each { |text| expect(prompt).to include(text) }
          fixture.fetch(:excludes).each { |text| expect(prompt).not_to include(text) }
          expect(schema_keys(prompt)).to eq(fixture[:schema]) if fixture.key?(:schema)
        end

        it "matches its recorded snapshot byte for byte" do
          expect_snapshot(name, prompt)
        end
      end
    end

    it "pins every retry case to a one-section schema" do
      retries = CASE_FIXTURES.select { |name, _| name.start_with?("case__retry__") }

      expect(retries.size).to eq(3)
      expect(retries.values.map { |fixture| fixture.fetch(:schema).size }).to all(eq(1))
    end
  end

  it "has no snapshot left behind for a combination that no longer exists" do
    expected = DailyExercise::LANGUAGES.flat_map { |language|
      ExerciseSection.thirds.map { |kind| kind.key.to_sym }.flat_map { |third|
        ExerciseSection.fourths.map { |kind| kind.key.to_sym }.flat_map { |fourth|
          DailyPlan::CODE_REVIEW_MODE_WEIGHTS.each_key.map { |mode| snapshot_path(language, third, fourth, mode).basename.to_s }
        }
      }
    }
    expected += (SHAPE_FIXTURES.keys + CASE_FIXTURES.keys).map { |name| "#{name}.txt" }

    expect(Dir.children(SNAPSHOT_DIR).sort).to eq(expected.sort)
  end
end
