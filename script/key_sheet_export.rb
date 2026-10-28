# Design notes: docs/code-notes/script/key_sheet_export.md
require_relative "review_baseline_export"

class KeySheetExport
  SHOWN_FIELDS = %w[snippet current_schema plan_excerpt problem_statement].freeze

  def initialize(user_id:, per_kind: ReviewBaselineExport::PER_KIND)
    @user_id  = user_id
    @per_kind = per_kind
  end

  def call
    ReviewBaselineExport.read_only { { "sections" => sections } }
  end

  private

  def sections
    taken = Hash.new(0)
    responses.each_with_object([]) do |response, entries|
      keyed_sections(response).each do |kind, section|
        next if taken[kind] >= @per_kind

        taken[kind] += 1
        entries << entry(kind, section)
      end
    end
  end

  def responses
    DailyResponse.where(user_id: @user_id).where.not(submitted_at: nil).includes(:daily_exercise).order(date: :desc)
  end

  def keyed_sections(response)
    response.daily_exercise.problem_set.select do |kind, section|
      ExerciseSection.find(kind)&.planted_key? && section.is_a?(Hash) && section.key?(PlantedKey::FIELD) &&
        response.section_reviewed?(kind)
    end
  end

  def entry(kind, section)
    { "kind" => kind, "scenario" => section["scenario"], "question" => section["question"],
      "shown" => section.slice(*SHOWN_FIELDS), "answer_key" => section[PlantedKey::FIELD] }
  end
end
