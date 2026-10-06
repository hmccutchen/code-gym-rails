# Checks that Gemini accepts the judge's verdict schema (#228). Each fixture
# is one request, billed to GEMINI_API_KEY, never to a user's stored key.
#
#   GEMINI_API_KEY=AIza... bin/rails runner script/check_gemini_structured_output.rb
#   GEMINI_API_KEY=AIza... bin/rails runner script/check_gemini_structured_output.rb FIXTURE [FIXTURE ...]
#
# FIXTURE names a file in spec/fixtures/judge without its extension.
require_relative "gemini_structured_output_check"

api_key = ENV["GEMINI_API_KEY"].presence
abort("GEMINI_API_KEY is not set.\n\n#{File.readlines(__FILE__).grep(/^#   /).join}") unless api_key

fixtures = ARGV.presence || GeminiStructuredOutputCheck::DEFAULT_FIXTURES
rows = GeminiStructuredOutputCheck.new(api_key: api_key, fixtures: fixtures).run
exit(1) unless rows.all? { |row| row.outcome == :parsed }
