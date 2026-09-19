# Measures how long AiService#generate_concept_reference takes against a live
# provider, so CONCEPT_REFERENCE_READ_TIMEOUT rests on numbers. Every call is
# billed to the key below. See ConceptReferenceCalibration for what is run.
#
#   ANTHROPIC_API_KEY=sk-ant-... bin/rails runner script/calibrate_concept_references.rb claude [--repeats N] [--concurrency N] [--timeout SECONDS] [BUCKET/CONCEPT ...]
#   GEMINI_API_KEY=...        bin/rails runner script/calibrate_concept_references.rb gemini [--repeats N] [--concurrency N] [--timeout SECONDS] [BUCKET/CONCEPT ...]
#
# With no BUCKET/CONCEPT pairs, ConceptReferenceCalibration.default_sample is
# run. --timeout replaces the deployed read timeout for the run only, to see
# how long a call that outlasts it actually takes to finish.
require "optparse"
require_relative "concept_reference_calibration"

usage   = File.readlines(__FILE__).grep(/^#   /).join
options = {}
parser  = OptionParser.new do |opts|
  opts.banner = usage
  opts.on("--repeats N", Integer)         { |n| options[:repeats] = n }
  opts.on("--concurrency N", Integer)     { |n| options[:concurrency] = n }
  opts.on("--timeout SECONDS", Integer)   { |n| options[:timeout] = n }
end

begin
  provider, *pairs = parser.parse(ARGV)
rescue OptionParser::ParseError => e
  abort("#{e.message}\n\n#{usage}")
end

key_variable = ConceptReferenceCalibration.key_variable_for(provider) or abort(usage)
api_key      = ENV[key_variable].presence or
  abort("#{key_variable} is not set. Calls are billed to it, never to a user's stored key.\n\n#{usage}")

sample = pairs.map { |pair| pair.split("/", 2) }
abort(usage) unless sample.all? { |pair| pair.size == 2 && pair.none?(&:blank?) }

begin
  calibration = ConceptReferenceCalibration.new(provider: provider, api_key: api_key, **options)
  sample.empty? ? calibration.run : calibration.run(sample)
rescue ArgumentError => e
  abort("#{e.message}\n\n#{usage}")
end
