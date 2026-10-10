# Side-by-side model comparison; see ModelComparison::CANDIDATES for the pairs.
USAGE = <<~TEXT.freeze
  ANTHROPIC_API_KEY=sk-ant-... bin/rails runner script/compare_models.rb generate  USER_ID
  ANTHROPIC_API_KEY=sk-ant-... bin/rails runner script/compare_models.rb review    DAILY_RESPONSE_ID
  ANTHROPIC_API_KEY=sk-ant-... bin/rails runner script/compare_models.rb duck      DAILY_EXERCISE_ID SECTION [MESSAGE]
  ANTHROPIC_API_KEY=sk-ant-... bin/rails runner script/compare_models.rb translate DAILY_RESPONSE_ID
  ANTHROPIC_API_KEY=sk-ant-... bin/rails runner script/compare_models.rb judge     USER_ID
  ANTHROPIC_API_KEY=sk-ant-... bin/rails runner script/compare_models.rb judge_fixtures
  ANTHROPIC_API_KEY=sk-ant-... bin/rails runner script/compare_models.rb judge_concept USER_ID CONCEPT [PER_RUNG]
  ANTHROPIC_API_KEY=sk-ant-... bin/rails runner script/compare_models.rb review_prose USER_ID [LIMIT]
  ANTHROPIC_API_KEY=sk-ant-... bin/rails runner script/compare_models.rb review_prose_fixtures
  ANTHROPIC_API_KEY=sk-ant-... bin/rails runner script/compare_models.rb review_calibration
TEXT

require_relative "model_comparison"

mode, id, *rest = ARGV
api_key = ENV["ANTHROPIC_API_KEY"].presence
known_modes = ModelComparison::CANDIDATES.keys + %w[judge_fixtures judge_concept review_prose_fixtures]

abort("ANTHROPIC_API_KEY is not set. Calls are billed to it, never to a user's stored key.\n\n#{USAGE}") unless api_key
abort(USAGE) unless known_modes.include?(mode)
abort(USAGE) if %w[judge_fixtures review_prose_fixtures review_calibration].exclude?(mode) && id.blank?

comparison = ModelComparison.new(api_key: api_key)

case mode
when "generate"       then comparison.generate(id)
when "review"         then comparison.review(id)
when "translate"      then comparison.translate(id)
when "judge"          then comparison.judge(id)
when "judge_fixtures" then comparison.judge_fixtures
when "review_prose_fixtures" then comparison.review_prose_fixtures
when "review_calibration" then comparison.review_calibration
when "judge_concept"
  concept, per_rung = rest
  per_rung = per_rung ? Integer(per_rung, exception: false) : 2
  abort(USAGE) if concept.blank?
  abort("PER_RUNG must be a positive integer.\n\n#{USAGE}") unless per_rung&.positive?

  comparison.judge_concept(id, concept, per_rung: per_rung)
when "review_prose"
  limit = rest.first ? Integer(rest.first, exception: false) : 5
  abort("LIMIT must be a positive integer.\n\n#{USAGE}") unless limit&.positive?

  comparison.review_prose(id, limit: limit)
when "duck"
  section, message = rest
  abort(USAGE) if section.blank?

  message ? comparison.duck(id, section: section, message: message) : comparison.duck(id, section: section)
end
