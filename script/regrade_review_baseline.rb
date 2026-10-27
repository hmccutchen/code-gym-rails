# Writes nothing: grading runs on unsaved records inside a read-only transaction; see docs/code-notes/script/review_stability.md.
require "optparse"
require_relative "model_comparison"

USAGE = <<~TEXT.freeze
  bin/rails runner script/regrade_review_baseline.rb EXPORT_PATH [--runs N] [--provider claude|openai|gemini]
  ANTHROPIC_API_KEY=sk-ant-... bin/rails runner script/regrade_review_baseline.rb EXPORT_PATH --run

  EXPORT_PATH  the file script/export_review_baseline.rb wrote
  (no --run)   plan only: sections by kind, call count and estimated cost, with no provider call
  --run        grade every exported section N times on that provider's production review route
  --runs N     grades per section (default #{ReviewStability::RUNS})
  --provider   claude (default), openai or gemini, billed to that provider's own environment key
TEXT

options = { runs: ReviewStability::RUNS, provider: "claude", run: false }
OptionParser.new do |parser|
  parser.on("--run") { options[:run] = true }
  parser.on("--runs N", Integer) { |count| options[:runs] = count }
  parser.on("--provider NAME", String) { |name| options[:provider] = name }
end.parse!(ARGV)

path = ARGV.first
abort(USAGE) if path.blank?
abort("No file at #{path}.") unless File.file?(path)
abort("--runs must be at least 2.\n\n#{USAGE}") unless options[:runs] >= 2
provider = ModelComparison::JUDGE_SHAPE_PROVIDERS[options[:provider]] or abort("Unknown provider #{options[:provider]}.\n\n#{USAGE}")
api_key  = ENV[provider[:key_variable]]
abort("Set #{provider[:key_variable]} to a key you own before --run.") if options[:run] && api_key.blank?

ModelComparison.new(api_key: api_key.presence || "plan-only").review_stability(
  path, runs: options[:runs], provider: options[:provider], run: options[:run]
)
