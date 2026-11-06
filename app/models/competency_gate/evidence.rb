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
    end

    def each
      return enum_for(:each) unless block_given?

      responses.find_in_batches(cursor: %i[date id], batch_size: @batch_size) do |batch|
        batch.each do |response|
          day = day_for(response)
          yield day if day
        end
      end
    end

    private

    def responses
      @user.daily_responses.submitted.reviewed
           .where(RUBRIC_STAMPED, version: ReviewedSectionResults::RUBRIC_VERSION).preload(:daily_exercise)
    end

    def day_for(response)
      return unless response.assessed_sections.any? { |section| ReviewedSectionResults.current_rubric?(response.ai_review[section]) }

      daily = response.daily_exercise.daily_kinds.map(&:key)
      results = ReviewedSectionResults.for(response, require_rubric: true, include_eased: true)
      optional = optional_state(response, daily)
      return if results.empty? && %i[none unknown].include?(optional)

      Day.new(results: results, optional: optional, daily: daily)
    end

    def optional_state(response, daily)
      optional = response.section_keys - daily
      return :none if optional.empty?
      return :unknown unless response.completion_evidence?

      (optional - response.answered_sections).empty? ? :complete : :incomplete
    end
  end
end
