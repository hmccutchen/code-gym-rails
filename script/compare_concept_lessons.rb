# Writes concepts' Learn write-ups with today's prompt, or with the candidate
# lesson prompt, into tmp/concept_lessons/comparison.md for a person to read.
# Calls are billed to ANTHROPIC_API_KEY, never to a user's stored key, and no
# ConceptReference, exercise or ApiUsage row is written.
#
#   ANTHROPIC_API_KEY=sk-ant-... bin/rails runner script/compare_concept_lessons.rb CONCEPT [CONCEPT ...]
#   ANTHROPIC_API_KEY=sk-ant-... bin/rails runner script/compare_concept_lessons.rb --candidate CONCEPT [CONCEPT ...]
#
# CONCEPT is a concept name, or BUCKET/CONCEPT for a concept in more than one
# bucket. Each run rewrites comparison.md from every lesson saved so far.
require_relative "concept_lesson_comparison"

candidate = ARGV.delete("--candidate").present?
api_key = ENV["ANTHROPIC_API_KEY"].presence
usage = File.readlines(__FILE__).grep(/^#   /).join

abort("ANTHROPIC_API_KEY is not set. Calls are billed to it, never to a user's stored key.\n\n#{usage}") unless api_key
abort(usage) if ARGV.empty?

begin
  ConceptLessonComparison.new(api_key: api_key, candidate: candidate).run(ARGV)
rescue ArgumentError => e
  abort("#{e.message}\n\n#{usage}")
end
