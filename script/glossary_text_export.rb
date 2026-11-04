# Design notes: docs/code-notes/script/glossary_text_export.md
require_relative "review_baseline_export"

class GlossaryTextExport
  EXERCISE_FIELDS = { "scenario" => "scenario", "question" => "question", "options" => "option", "request" => "request",
                      "problem_statement" => "problem_statement", "why" => "why", "plan_excerpt" => "plan_excerpt" }.freeze
  REFERENCE_FIELDS = { "tagline" => "reference_tagline", "explanation" => "reference_explanation",
                       "tradeoffs" => "reference_tradeoff", "senior_lens" => "reference_senior_lens" }.freeze

  def initialize(out:)
    @out = out
  end

  def call
    ReviewBaselineExport.read_only do
      DailyResponse.reviewed.select(:id, :ai_review, :review_alternates).find_each { |response| review_rows(response).each { |row| write(row) } }
      DailyExercise.select(:id, :problem_set).find_each { |exercise| exercise_rows(exercise).each { |row| write(row) } }
    end
  end

  private

  def review_rows(response)
    response.ai_review.flat_map do |section, review|
      next [] unless review.is_a?(Hash)

      id = "#{response.id}:#{section}"
      prose = DailyResponse::AI_REVIEW_FIELDS.keys.flat_map { |field| DailyResponse.review_points(review[field]).map { |text| row("review", id, field, text) } }
      reason = response.difficulty_for(section)&.dig("reason")
      alternates = Array(response.review_alternates[section]).map { |text| row("review", id, "alternate", text) }
      prose + [ (row("review", id, "difficulty_reason", reason) if reason.present?) ].compact + alternates
    end
  end

  def exercise_rows(exercise)
    exercise.problem_set.flat_map do |section, data|
      next [] unless data.is_a?(Hash)

      id = "#{exercise.id}:#{section}"
      reference = data["reference"].is_a?(Hash) ? data["reference"] : {}
      text_rows(data, EXERCISE_FIELDS, id) + text_rows(reference, REFERENCE_FIELDS, id)
    end
  end

  def text_rows(data, fields, id)
    fields.flat_map { |key, field| Array(data[key]).grep(String).reject(&:blank?).map { |text| row("exercise", id, field, text) } }
  end

  def row(source, id, field, text) = { source: source, id: id, field: field, text: text }

  def write(row) = @out.puts(JSON.generate(row))
end
