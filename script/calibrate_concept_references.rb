# Times AiService#generate_concept_reference against a live, billed provider to ground CONCEPT_REFERENCE_READ_TIMEOUT.
USAGE = <<~TEXT.freeze
  ANTHROPIC_API_KEY=sk-ant-... bin/rails runner script/calibrate_concept_references.rb claude [--repeats N] [--concurrency N] [--timeout SECONDS] [BUCKET/CONCEPT ...]
  GEMINI_API_KEY=...        bin/rails runner script/calibrate_concept_references.rb gemini [--repeats N] [--concurrency N] [--timeout SECONDS] [BUCKET/CONCEPT ...]

  With no BUCKET/CONCEPT pairs, ConceptReferenceCalibration.default_sample runs.
  --timeout replaces the deployed read timeout for this run only.
TEXT

require "optparse"
require_relative "concept_reference_calibration"

options = {}
parser  = OptionParser.new do |opts|
  opts.banner = USAGE
  opts.on("--repeats N", Integer)         { |n| options[:repeats] = n }
  opts.on("--concurrency N", Integer)     { |n| options[:concurrency] = n }
  opts.on("--timeout SECONDS", Integer)   { |n| options[:timeout] = n }
end

begin
  provider, *pairs = parser.parse(ARGV)
rescue OptionParser::ParseError => e
  abort("#{e.message}\n\n#{USAGE}")
end

key_variable = ConceptReferenceCalibration.key_variable_for(provider) or abort(USAGE)
api_key      = ENV[key_variable].presence or
  abort("#{key_variable} is not set. Calls are billed to it, never to a user's stored key.\n\n#{USAGE}")

sample = pairs.map { |pair| pair.split("/", 2) }
abort(USAGE) unless sample.all? { |pair| pair.size == 2 && pair.none?(&:blank?) }

begin
  calibration = ConceptReferenceCalibration.new(provider: provider, api_key: api_key, **options)
  sample.empty? ? calibration.run : calibration.run(sample)
rescue ArgumentError => e
  abort("#{e.message}\n\n#{USAGE}")
end
