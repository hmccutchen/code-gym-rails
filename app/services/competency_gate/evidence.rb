class CompetencyGate
  # A user's reviewed days as the gate reads them, oldest first: every
  # submitted response graded under the current rubric, with no cap. The fold
  # keeps an earned size for as long as nothing undoes it, so a window over
  # recent days would forget a size whose earning days had aged out. Batches
  # bound memory, not history.
  class Evidence
    include Enumerable

    BATCH_SIZE = 100

    # A review graded before the rubric existed, or by a worker still running
    # older code, carries no stamp; its ratings had no shared definition.
    RUBRIC_STAMPED = "jsonb_path_exists(ai_review, '$.*.rubric ? (@ == $version)', jsonb_build_object('version', CAST(:version AS integer)))"

    def initialize(user, batch_size: BATCH_SIZE)
      @user = user
      @batch_size = batch_size
      @fixed_kinds = ExerciseSection.fixed.map(&:key)
    end

    def each
      return enum_for(:each) unless block_given?

      responses.find_in_batches(cursor: %i[date id], batch_size: @batch_size) do |batch|
        batch.each { |response| yield day_for(response) }
      end
    end

    private

    def responses
      @user.daily_responses.submitted.where.not(ai_review: [ nil, {} ])
           .where(RUBRIC_STAMPED, version: AiService::RUBRIC_VERSION).preload(:daily_exercise)
    end

    def day_for(response)
      Day.new(results: ReviewedSectionResults.for(response, require_rubric: true), optional: optional_state(response))
    end

    def optional_state(response)
      optional = response.section_keys - @fixed_kinds
      return :none if optional.empty?

      (optional - response.answered_sections).empty? ? :complete : :incomplete
    end
  end
end
