require "rails_helper"

RSpec.describe SectionKindSettings do
  def settings(stored: {}, section_count: nil, **values)
    defaults = { section_kind_weights: {}, excluded_section_kinds: [], section_kind_levels: {}, locked_section_kinds: [],
                 daily_section_kinds: [] }
    described_class.new(**defaults.merge(values), stored: defaults.merge(stored), section_count: section_count)
  end

  let(:thirds) { ExerciseSection.thirds.map(&:key) }

  it "has no problems and no change for settings equal to the stored ones" do
    unchanged = settings(section_kind_weights: { "challenge" => 2.0 }, stored: { section_kind_weights: { "challenge" => 2.0 } })

    expect(unchanged.problems).to be_empty
    expect(unchanged.changed?).to be(false)
  end

  it "leaves an unchanged field alone, so a kind retired from the registry never refuses an unrelated save" do
    retired = { section_kind_levels: { "retired_kind" => "senior" }, locked_section_kinds: [ "retired_kind" ] }

    expect(settings(**retired, stored: retired).problems).to be_empty
    expect(settings(**retired, stored: {}).problems.map(&:first)).to include(:section_kind_levels, :locked_section_kinds)
  end

  it "refuses a field it doesn't know, so a misspelt column fails instead of going unchecked" do
    expect { described_class.new(section_kind_weight: {}) }.to raise_error(ArgumentError)
  end

  it "says which fields changed" do
    edited = settings(locked_section_kinds: [ "pattern" ], section_kind_levels: { "pattern" => "senior" })

    expect(edited.changed?).to be(true)
    expect(edited.changed?(:section_kind_weights)).to be(false)
    expect(edited.changed?(:section_kind_weights, :locked_section_kinds)).to be(true)
  end

  it "checks only the weights a save adds or changes, against the rotatable kinds and the multipliers" do
    stored = { section_kind_weights: { "retired_kind" => 4.0 } }

    expect(settings(section_kind_weights: { "retired_kind" => 4.0, "challenge" => 0.5 }, stored: stored).problems).to be_empty
    expect(settings(section_kind_weights: { "nope" => 3 }).problems).to contain_exactly(
      [ :section_kind_weights, "names an unknown section kind: nope" ],
      [ :section_kind_weights, a_string_starting_with("has an unsupported weight for nope") ]
    )
    expect(settings(section_kind_weights: [ 1 ]).problems).to eq([ [ :section_kind_weights, "must be an object" ] ])
  end

  it "refuses a weight on a kind the pair makes daily" do
    expect(settings(daily_section_kinds: %w[challenge code_review], section_kind_weights: { "challenge" => 2.0 }).problems)
      .to eq([ [ :section_kind_weights, "names an unknown section kind: challenge" ] ])
  end

  it "accepts a weight on a stored extra section the setting leaves rotating" do
    expect(settings(daily_section_kinds: %w[code_review design_comparison challenge], section_count: 2,
                    section_kind_weights: { "challenge" => 2.0 }).problems).to eq([])
  end

  it "refuses a weight on an extra section the setting puts in every set" do
    expect(settings(daily_section_kinds: %w[code_review design_comparison challenge], section_count: 3,
                    section_kind_weights: { "challenge" => 2.0 }).problems)
      .to eq([ [ :section_kind_weights, "names an unknown section kind: challenge" ] ])
  end

  it "checks emptied slots against the pair alone, since rotation fills no place a chosen extra section holds" do
    pinned = settings(daily_section_kinds: %w[code_review design_comparison challenge], section_count: 3,
                      excluded_section_kinds: thirds - %w[challenge])

    expect(pinned.problems).to eq([])
  end

  it "refuses an exclusion that empties an optional slot, whether the exclusions or the pair moved" do
    expect(settings(excluded_section_kinds: thirds).problems)
      .to include([ :excluded_section_kinds, "must leave at least one third section in rotation" ])

    moved_pair = settings(excluded_section_kinds: %w[architecture security_review challenge], daily_section_kinds: %w[parsons_problem code_review],
                          stored: { excluded_section_kinds: %w[architecture security_review challenge] })
    expect(moved_pair.problems).to include([ :excluded_section_kinds, "must leave at least one third section in rotation" ])
  end

  it "refuses levels and locks outside the vocabularies, and a lock with no level" do
    expect(settings(section_kind_levels: { "pattern" => "nope" }).problems)
      .to eq([ [ :section_kind_levels, "has an unsupported level for pattern, which must be one of #{KindDifficulty::LEVELS.join(', ')}" ] ])
    expect(settings(locked_section_kinds: [ "pattern" ]).problems)
      .to eq([ [ :locked_section_kinds, "locks pattern without a difficulty target" ] ])
    expect(settings(locked_section_kinds: "pattern").problems).to eq([ [ :locked_section_kinds, "must be a list" ] ])
  end

  it "refuses a pair DailyKinds does not accept" do
    expect(settings(daily_section_kinds: %w[nope]).problems.map(&:first)).to eq([ :daily_section_kinds ])
  end

  it "names the slots a set of exclusions would empty for any pair" do
    expect(settings(excluded_section_kinds: thirds).emptied_slots.transform_values { |kinds| kinds.map(&:key) })
      .to eq(third: thirds)
    expect(settings.emptied_slots).to be_empty
  end

  it "merges the stored entries for controls the pair hides back into a save, and leaves other fields alone" do
    hidden = settings(daily_section_kinds: %w[challenge parsons_problem], section_kind_weights: { "challenge" => 2.0 },
                      excluded_section_kinds: %w[parsons_problem])

    expect(hidden.keep_unrendered(section_kind_weights: { "architecture" => 0.5 }, excluded_section_kinds: []))
      .to eq(section_kind_weights: { "challenge" => 2.0, "architecture" => 0.5 }, excluded_section_kinds: %w[parsons_problem])
    expect(hidden.keep_unrendered(name: "Kept")).to eq(name: "Kept")
  end

  it "keeps the stored weight of an extra section the setting puts in every set, since Setup renders no slider for it" do
    pinned = settings(daily_section_kinds: %w[code_review design_comparison challenge], section_count: 3,
                      section_kind_weights: { "challenge" => 2.0 })

    expect(pinned.keep_unrendered(section_kind_weights: {})).to eq(section_kind_weights: { "challenge" => 2.0 })
  end
end
