class ReviewGrading
  # grade, judge_prose, assess_difficulty, translate and day_context raise; provider_key and judges_prose are values.
  Provider = Data.define(:grade, :judge_prose, :assess_difficulty, :translate, :day_context, :provider_key, :judges_prose)

  def self.call(user:, exercise:, response:, sections:, coach:, providers:)
    new(user, exercise, response, sections, coach, providers).call
  end

  def self.grade_section(section, context:, user:, exercise:, response:, coach:, provider:)
    new(user, exercise, response, [ section ], coach, -> { provider }).grade_section(section, context)
  end

  def initialize(user, exercise, response, sections, coach, providers)
    @user      = user
    @exercise  = exercise
    @response  = response
    @sections  = sections
    @coach     = coach
    @providers = providers
  end

  def call
    difficulty = CallerZoneThread.start { safe_difficulty_assessment }
    provider   = @providers.call
    translate_before_grading(provider)

    context = provider.day_context.call(@coach, @exercise, @response)
    threads = @sections.map { |section| CallerZoneThread.start { grade_section(section, context) } }

    results = threads.map(&:value).to_h
    merge_difficulty!(results, awaited_difficulty(difficulty))
    results
  end

  def grade_section(section, context)
    provider = @providers.call
    review   = provider.grade.call(@user, @exercise, @response, section, context)
    review   = gaps_beside_their_prose(judged_review(provider, section, rated(section, review)))
    [ section, { ok: true, review: review } ]
  rescue AiService::Error, *AiService::INFRASTRUCTURE_ERRORS => e
    [ section, { ok: false, error_code: AiService.error_code_for(e), failure: ProviderFailure.classify(e),
                 provider: e.try(:provider) || provider&.provider_key,
                 quota_id: e.try(:quota_id), retry_after: e.try(:retry_after), failed_at: Time.current } ]
  end

  private

  def awaited_difficulty(thread)
    thread.join(AiService::DIFFICULTY_ASSESSMENT_GRACE_SECONDS) ? thread.value : {}
  end

  def safe_difficulty_assessment
    @providers.call.assess_difficulty.call(@user, @exercise, sections: @sections)
  rescue StandardError => e
    Rails.logger.warn("[difficulty] assessment failed: #{e.message}")
    {}
  end

  def translate_before_grading(provider)
    @sections.each do |section|
      next unless ExerciseSection.for(section).translated_before_grading?
      next if @response.translated?(section) || !@response.answered?(section)

      pseudocode = @response.answers[section].to_s
      next unless translatable_length?(pseudocode)

      code = provider.translate.call(@user, @exercise, section: section, pseudocode: pseudocode)
      @response.record_translation!(section, code: code, pseudocode: pseudocode)
    rescue StandardError => e
      Rails.logger.warn("[pseudocode] review-time translation failed: #{e.message}")
    end
  end

  def translatable_length?(pseudocode)
    return true if pseudocode.length <= ExerciseSection::PseudocodeToCode::MAX_PSEUDOCODE_LENGTH

    Rails.logger.warn(
      "[pseudocode] review-time translation skipped: plan is #{pseudocode.length} characters, " \
      "over the #{ExerciseSection::PseudocodeToCode::MAX_PSEUDOCODE_LENGTH} limit"
    )
    false
  end

  def merge_difficulty!(results, difficulty)
    results.each do |section, result|
      next unless result[:ok] && difficulty[section]

      result[:review]["difficulty"] = difficulty[section]
    end
  end

  def rated(section, review)
    fixed = ExerciseSection.for(section).fixed_rating(
      section: @exercise.problem_set[section] || {}, answer: @response.answer_for(section)
    )
    return review.merge("rating" => fixed).except("essential_gaps") if fixed

    checked_against_rubric(section, review)
  end

  def checked_against_rubric(section, review)
    check  = RubricCheck.new(review)
    rating = ConceptMastery::AI_RATING_RANK.key?(review["rating"]) ? review["rating"] : "invalid"
    Rails.logger.info("[rubric_check] user=#{@user.id} section=#{section} rating=#{rating} " \
                      "essential=#{check.essential_gaps&.size || 'unknown'} missed=#{check.missed_count} " \
                      "agrees=#{check.agrees?.nil? ? 'unknown' : check.agrees?}")
    check.essential_gaps ? review.merge("essential_gaps" => check.essential_gaps) : review.except("essential_gaps")
  end

  def gaps_beside_their_prose(review)
    original = review[ReviewProseVerdict::ORIGINAL_KEY]
    return review unless original.is_a?(Hash) && review.key?("essential_gaps") && original["missed"] != review["missed"]

    review.except("essential_gaps").merge(ReviewProseVerdict::ORIGINAL_KEY => original.merge("essential_gaps" => review["essential_gaps"]))
  end

  def judged_review(provider, section, review)
    return review unless ReviewProseJudge.enabled? && provider.judges_prose

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    verdict = provider.judge_prose.call(@user, ExerciseSection.for(section), review, coach: @coach)
    log_review_judge(section, verdict, started)
    verdict.apply(review)
  rescue StandardError => e
    Rails.logger.warn("[review_judge_fallback] user=#{@user.id} section=#{section} reason=#{AiService.judge_fallback_reason(e)}")
    review
  end

  def log_review_judge(section, verdict, started)
    ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000).round
    Rails.logger.info("[review_judge] user=#{@user.id} section=#{section} status=#{verdict.status} " \
                      "issues=#{verdict.issues.map { |issue| issue[:type] }.uniq.join(',')} " \
                      "merges=#{verdict.merges.to_json} ms=#{ms}")
  end
end
