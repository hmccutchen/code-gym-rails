class CompetencyGate
  # No cap: the fold keeps an earned size until something undoes it, so a recent window would forget it. Batches bound memory.
  class Evidence
    include Enumerable

    BATCH_SIZE = 100

    # Reviews graded before the rubric, or by older code, carry no stamp; their ratings had no shared definition.
    RUBRIC_STAMPED = "jsonb_path_exists(ai_review, '$.*.rubric ? (@ == $version)', jsonb_build_object('version', CAST(:version AS integer)))"

    def initialize(user, batch_size: BATCH_SIZE)
      @user = user
      @batch_size = batch_size
      @fixed_kinds = ExerciseSection.fixed.map(&:key)
    end

    def each
      return enum_for(:each) unless block_given?

      responses.find_in_batches(cursor: %i[date id], batch_size: @batch_size) do |batch|
        batch.each { |response| yield day_for(response) if ReviewedSectionResults.readable?(response) }
      end
    end

    private

    def responses
      @user.daily_responses.submitted.where.not(ai_review: [ nil, {} ])
           .where(RUBRIC_STAMPED, version: AiService::RUBRIC_VERSION).preload(:daily_exercise)
    end

    def day_for(response)
      Day.new(results: ReviewedSectionResults.for(response, require_rubric: true, include_eased: true), optional: optional_state(response))
    end

    # Assumes well-formed JSON; the readable? check above guarantees it.
    def optional_state(response)
      optional = response.section_keys - @fixed_kinds
      return :none if optional.empty?

      (optional - response.answered_sections).empty? ? :complete : :incomplete
    end
  end
end
