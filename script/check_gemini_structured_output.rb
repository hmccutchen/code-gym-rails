# Checks Gemini accepts the judge's verdict schema (#228); one request per fixture, billed to GEMINI_API_KEY.
USAGE = <<~TEXT.freeze
  GEMINI_API_KEY=AIza... bin/rails runner script/check_gemini_structured_output.rb
  GEMINI_API_KEY=AIza... bin/rails runner script/check_gemini_structured_output.rb FIXTURE [FIXTURE ...]

  FIXTURE names a file in spec/fixtures/judge without its extension.
TEXT

require_relative "gemini_structured_output_check"

api_key = ENV["GEMINI_API_KEY"].presence
abort("GEMINI_API_KEY is not set.\n\n#{USAGE}") unless api_key

fixtures = ARGV.presence || GeminiStructuredOutputCheck::DEFAULT_FIXTURES
rows = GeminiStructuredOutputCheck.new(api_key: api_key, fixtures: fixtures).run
exit(1) unless rows.all? { |row| row.outcome == :parsed }
