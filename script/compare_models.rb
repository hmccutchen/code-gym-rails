# Side-by-side model comparison. See ModelComparison::CANDIDATES for the pairs.
#
#   ANTHROPIC_API_KEY=sk-ant-... bin/rails runner script/compare_models.rb generate  USER_ID
#   ANTHROPIC_API_KEY=sk-ant-... bin/rails runner script/compare_models.rb review    DAILY_RESPONSE_ID
#   ANTHROPIC_API_KEY=sk-ant-... bin/rails runner script/compare_models.rb duck      DAILY_EXERCISE_ID SECTION [MESSAGE]
#   ANTHROPIC_API_KEY=sk-ant-... bin/rails runner script/compare_models.rb translate DAILY_RESPONSE_ID
require_relative "model_comparison"

mode, id, *rest = ARGV
api_key = ENV["ANTHROPIC_API_KEY"].presence
usage   = File.readlines(__FILE__).grep(/^#   /).join

abort("ANTHROPIC_API_KEY is not set. Calls are billed to it, never to a user's stored key.\n\n#{usage}") unless api_key
abort(usage) unless ModelComparison::CANDIDATES.key?(mode) && id.present?

comparison = ModelComparison.new(api_key: api_key)

case mode
when "generate"  then comparison.generate(id)
when "review"    then comparison.review(id)
when "translate" then comparison.translate(id)
when "duck"
  section, message = rest
  abort(usage) if section.blank?

  message ? comparison.duck(id, section: section, message: message) : comparison.duck(id, section: section)
end
