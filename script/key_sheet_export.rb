# Design notes: docs/code-notes/script/key_sheet_export.md
require_relative "review_baseline_export"

class KeySheetExport
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
      language = response.daily_exercise.language
      keyed_sections(response).each do |kind, section|
        next if taken[[ kind, language ]] >= @per_kind

        taken[[ kind, language ]] += 1
        entries << entry(kind, language, section)
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

  def entry(kind, language, section)
    { "kind" => kind, "language" => language, "scenario" => section["scenario"], "question" => section["question"],
      "shown" => section.slice(*ExerciseSection.for(kind).key_context_fields), "answer_key" => section[PlantedKey::FIELD] }
  end
end
