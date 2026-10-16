# Run with bin/rails runner -e test, only for a deliberate gate change: docs/decisions/competency-gate.md.
require "json"

PROFILES = {
  "grows_steadily"    => { favourable: 0.85, too_hard: 0.02, optional_complete: 0.9, level_change: 0.00 },
  "grows_then_brakes" => { favourable: 0.75, too_hard: 0.12, optional_complete: 0.7, level_change: 0.02 },
  "brakes_often"      => { favourable: 0.45, too_hard: 0.35, optional_complete: 0.5, level_change: 0.03 },
  "holds_on_one_kind" => { favourable: 0.60, too_hard: 0.05, optional_complete: 0.8, level_change: 0.00, poor_kind: "design_comparison" },
  "mixed_with_eased"  => { favourable: 0.65, too_hard: 0.10, optional_complete: 0.6, level_change: 0.05, eased: 0.15 },
  "changes_levels"    => { favourable: 0.80, too_hard: 0.05, optional_complete: 0.8, level_change: 0.10 }
}.freeze

DEFAULT_PAIR = DailyKinds::DEFAULT.map(&:key)
OPTIONAL     = ExerciseSection.keys - DEFAULT_PAIR
DAYS         = 50
FIXTURE      = Rails.root.join("spec/fixtures/competency_gate/default_pair_histories.json")

def generate(profile, seed)
  rng    = Random.new(seed)
  levels = Hash.new("mid_level")
  size   = 2
  Array.new(DAYS) do
    optional = OPTIONAL.sample(rng.rand(0..[ size - 2, 2 ].max), random: rng)
    complete = optional.empty? || rng.rand < profile[:optional_complete]
    answered = complete ? optional : optional.first(optional.size - 1)
    kinds    = (DEFAULT_PAIR + answered).sort_by { |kind| ExerciseSection.keys.index(kind) }
    results  = kinds.map { |kind| result_for(kind, profile, levels, rng) }
    size     = (size + rng.rand(-1..1)).clamp(2, 4)
    { "results" => results, "optional" => optional.empty? ? "none" : (complete ? "complete" : "incomplete") }
  end
end

def result_for(kind, profile, levels, rng)
  levels[kind] = KindDifficulty::LEVELS.sample(random: rng) if rng.rand < profile[:level_change]
  good = kind != profile[:poor_kind] && rng.rand < profile[:favourable]
  self_rating = rng.rand < profile[:too_hard] ? "too_hard" : (rng.rand < 0.1 ? "too_easy" : "right_level")
  [ kind, levels[kind], good ? %w[solid strong].sample(random: rng) : %w[beginner developing].sample(random: rng),
    self_rating, rng.rand < profile.fetch(:eased, 0.03) ]
end

def gate_day(day)
  results = day["results"].map do |kind, level, ai, self_rating, eased|
    ReviewedSectionResults::Result.new(date: nil, kind: kind, level: level, ai_rating: ai, self_rating: self_rating, eased: eased)
  end
  CompetencyGate::Day.new(results: results, optional: day["optional"].to_sym, daily: DEFAULT_PAIR)
end

histories = PROFILES.flat_map do |name, profile|
  (name.include?("brakes") ? [ 1, 2 ] : [ 1 ]).map do |seed|
    days  = generate(profile, seed)
    plans = CompetencyGate.plans(days.map { |day| gate_day(day) }, evidence: true)
    { "name" => "#{name}_#{seed}", "days" => days, "plans" => JSON.parse(plans.map(&:to_h).to_json) }
  end
end

File.write(FIXTURE, JSON.generate("histories" => histories))
puts "Wrote #{histories.size} histories to #{FIXTURE.relative_path_from(Rails.root)}"
