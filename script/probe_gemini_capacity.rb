# Spends a Gemini key's whole daily allowance finding which limit stops it; run after the Pacific reset, never in CI.
USAGE = <<~TEXT.freeze
  GEMINI_API_KEY=AIza... bin/rails runner script/probe_gemini_capacity.rb --user ID
  GEMINI_API_KEY=AIza... bin/rails runner script/probe_gemini_capacity.rb --user ID --no-pace
  GEMINI_API_KEY=AIza... bin/rails runner script/probe_gemini_capacity.rb --user ID --pace 20 --max-days 3

  --user ID     a stored account whose history the prompts are built from (required)
  --pace S      seconds between calls, so the daily limit trips before the per-minute one (default 15)
  --no-pace     no wait between calls, to measure the per-minute limit instead
  --max-days N  stop after N tester-days even without a 429
  --out DIR     where refused replies are written (default tmp/gemini_probe)
TEXT

require_relative "gemini_capacity_probe"

options = { pace: GeminiCapacityProbe::DEFAULT_PACE_SECONDS, out: Rails.root.join(GeminiCapacityProbe::OUTPUT_DIR) }
OptionParser.new do |parser|
  parser.on("--user ID", Integer) { |id| options[:user] = id }
  parser.on("--pace SECONDS", Float) { |seconds| options[:pace] = seconds }
  parser.on("--no-pace") { options[:pace] = 0 }
  parser.on("--max-days N", Integer) { |n| options[:max_days] = n }
  parser.on("--out DIR") { |dir| options[:out] = dir }
end.parse!(ARGV)

abort("GEMINI_API_KEY is not set.\n\n#{USAGE}") unless ENV["GEMINI_API_KEY"].present?
abort("--user ID is required.\n\n#{USAGE}") unless options[:user]
user = User.active.find_by(id: options[:user]) or abort("No active user with id #{options[:user]}.")

GeminiCapacityProbe.new(api_key: ENV["GEMINI_API_KEY"], user: user, pace: options[:pace],
                        max_days: options[:max_days], output_dir: options[:out]).run
