class ResponseReview
  Outcome = Data.define(:status, :successes, :failures, :missing, :error) do
    def self.of(status, successes: {}, failures: {}, missing: [], error: nil)
      new(status: status, successes: successes, failures: failures, missing: missing, error: error)
    end
  end

  def initialize(response, user:, reviewer: nil)
    @response = response
    @user     = user
    @reviewer = reviewer
  end

  def call = Time.use_zone(@user.effective_time_zone) { run }

  private

  def run
    return Outcome.of(:not_submitted) unless @response.submitted?
    return Outcome.of(:already_reviewed) if missing_sections.empty?

    @claim = @response.claim_reviewing!
    return Outcome.of(:busy) unless @claim

    @response.reload
    return release_and(Outcome.of(:already_reviewed)) if missing_sections.empty?

    review(missing_sections)
  rescue ActiveRecord::RecordNotFound
    Outcome.of(:set_cleared)
  rescue AiService::Error => e
    release_and(Outcome.of(:provider_error, error: e))
  rescue StandardError
    @response.release_reviewing!(@claim) if @claim
    raise
  end

  def review(missing)
    first_batch = @response.ai_review.blank?
    results     = reviewer.review_sections(@user, @response.daily_exercise, @response, sections: missing)
    successes   = results.select { |_, result| result[:ok] }
    failures    = results.reject { |_, result| result[:ok] }

    return Outcome.of(:busy) unless store(successes, failures, first_batch: first_batch)

    @response.release_reviewing!(@claim)
    after_review(successes.keys) if successes.any?
    Outcome.of(status_for(successes, failures), successes: successes, failures: failures, missing: missing)
  end

  def reviewer = @reviewer ||= AiService.for(@user)

  def missing_sections = @response.section_keys - Array(@response.ai_review&.keys)

  def store(successes, failures, first_batch:)
    ActiveRecord::Base.transaction do
      @response.lock!
      next false unless @response.reviewing_since == @claim

      if successes.any?
        @response.ai_review = (@response.ai_review || {}).merge(successes.transform_values { |result| result[:review] })
        @response.review_provider = @user.provider
        ConceptMastery.record_review!(@response, sections: successes.keys, apply_session_countdown: first_batch)
      end
      @response.review_errors = @response.review_errors.except(*successes.keys)
                                         .merge(failures.transform_values { |result| stored_failure(result) })
      @response.save!
    end
  end

  def status_for(successes, failures)
    return :ready if failures.empty?

    successes.any? ? :partial : :failed
  end

  def release_and(outcome)
    @response.release_reviewing!(@claim) if @claim
    outcome
  end

  def after_review(sections)
    @user.clear_stale_generation_error!
    log_diagnostics(sections)
    log_pseudocode_diagnostics(sections)
  end

  def stored_failure(result)
    { "kind" => result[:failure], "provider" => result[:provider], "quota_id" => result[:quota_id],
      "retry_after" => result[:retry_after], "at" => (result[:failed_at] || Time.current).iso8601 }.compact
  end

  def log_diagnostics(sections)
    payload = {
      event: "review",
      user_id: @response.user_id,
      date: @response.daily_exercise.date.to_s,
      sections: sections.index_with { |section|
        { ai_rating: @response.ai_rating_for(section), self_rating: @response.self_rating_for(section) }
      }
    }

    Rails.logger.info("[difficulty_diagnostics] #{payload.to_json}")
  end

  def log_pseudocode_diagnostics(sections)
    section = ExerciseSection::PseudocodeToCode.key
    return unless sections.include?(section)

    critiqued = @response.critiqued?(section)
    gaps      = ExerciseSection::PseudocodeToCode.normalize_critique(@response.pseudocode_round(section)["critique"]).size
    missed    = DailyResponse.review_points(graded_missed(@response.ai_review&.dig(section))).size

    Rails.logger.info(
      "[pseudocode] user=#{@response.user_id} date=#{@response.daily_exercise.date} phase=review " \
      "critiqued=#{critiqued} gaps=#{gaps} missed=#{missed} " \
      "disagreement=#{critiqued && gaps.zero? && missed.positive?}"
    )
  end

  def graded_missed(review)
    return nil unless review.is_a?(Hash)

    review.dig(ReviewProseVerdict::ORIGINAL_KEY, "missed") || review["missed"]
  end
end
