# Side-by-side model comparison. See ModelComparison::CANDIDATES for the pairs.
#
#   ANTHROPIC_API_KEY=sk-ant-... bin/rails runner script/compare_models.rb generate  USER_ID
#   ANTHROPIC_API_KEY=sk-ant-... bin/rails runner script/compare_models.rb review    DAILY_RESPONSE_ID
#   ANTHROPIC_API_KEY=sk-ant-... bin/rails runner script/compare_models.rb duck      DAILY_EXERCISE_ID SECTION [MESSAGE]
#   ANTHROPIC_API_KEY=sk-ant-... bin/rails runner script/compare_models.rb translate DAILY_RESPONSE_ID
#   ANTHROPIC_API_KEY=sk-ant-... bin/rails runner script/compare_models.rb judge     USER_ID
#   ANTHROPIC_API_KEY=sk-ant-... bin/rails runner script/compare_models.rb judge_fixtures
require_relative "model_comparison"

mode, id, *rest = ARGV
api_key = ENV["ANTHROPIC_API_KEY"].presence
usage   = File.readlines(__FILE__).grep(/^#   /).join
known_modes = ModelComparison::CANDIDATES.keys + [ "judge_fixtures" ]

abort("ANTHROPIC_API_KEY is not set. Calls are billed to it, never to a user's stored key.\n\n#{usage}") unless api_key
abort(usage) unless known_modes.include?(mode)
abort(usage) if mode != "judge_fixtures" && id.blank?

comparison = ModelComparison.new(api_key: api_key)

case mode
when "generate"       then comparison.generate(id)
when "review"         then comparison.review(id)
when "translate"      then comparison.translate(id)
when "judge"          then comparison.judge(id)
when "judge_fixtures" then comparison.judge_fixtures
when "duck"
  section, message = rest
  abort(usage) if section.blank?

  message ? comparison.duck(id, section: section, message: message) : comparison.duck(id, section: section)
end
