class ResponsesController < ApplicationController
  include ProviderCallLimits
  include ProviderFailureRendering

  limit_provider_calls only: [ :explain_differently, :follow_ups, :duck_thread, :pseudocode_critique ]
  before_action :set_response, only: [ :review, :email_review, :explain_differently, :follow_ups, :start_over ]
  before_action :require_reviewed_section!, only: [ :explain_differently, :follow_ups ]

  MAX_DUCK_TURNS_PER_SECTION = 6

  MAX_DUCK_MESSAGE_LENGTH = 2_000
  MAX_DUCK_THREAD_ENTRIES = MAX_DUCK_TURNS_PER_SECTION * 2

  DUCK_REPLY_BYTES_PER_TOKEN = 4
  DUCK_ASSISTANT_REPLY_BYTE_ALLOWANCE = AiService::DUCK_RESPONSE_MAX_TOKENS * DUCK_REPLY_BYTES_PER_TOKEN
  MAX_DUCK_THREAD_BYTES = MAX_DUCK_TURNS_PER_SECTION *
    (MAX_DUCK_MESSAGE_LENGTH * 4 + DUCK_ASSISTANT_REPLY_BYTE_ALLOWANCE)

  def create
    exercise = current_user.daily_exercises.for_date.first
    return head :not_found unless exercise

    outcome = save_answers_under_lock(exercise)
    return render_stale_answers if outcome == :stale

    enqueue_concept_references(exercise) if outcome == :newly_submitted
    render_save_result(outcome != :failed)
  end

  # POST /responses/:id/review
  def review
    return redirect_to root_path, alert: t("flash.responses.not_submitted") unless @response.submitted?

    missing = @response.section_keys - Array(@response.ai_review&.keys)
    return redirect_to review_anchor, notice: t("flash.responses.already_reviewed") if missing.empty?

    unless claim_review!
      return redirect_to root_path, alert: t("flash.responses.review_already_running")
    end

    missing = @response.section_keys - Array(@response.ai_review&.keys)
    if missing.empty?
      release_review_claim!
      return redirect_to review_anchor, notice: t("flash.responses.already_reviewed")
    end

    first_batch = @response.ai_review.blank?
    results = AiService.for(current_user).review_sections(current_user, @response.daily_exercise, @response, sections: missing)
    successes = results.select { |_, r| r[:ok] }
    failures  = results.reject { |_, r| r[:ok] }

    ActiveRecord::Base.transaction do
      @response.lock!

      if successes.any?
        @response.ai_review = (@response.ai_review || {}).merge(successes.transform_values { |r| r[:review] })
        @response.review_provider = current_user.provider
        ConceptMastery.record_review!(@response, sections: successes.keys, apply_session_countdown: first_batch)
      end
      @response.review_errors = @response.review_errors
                                          .except(*successes.keys)
                                          .merge(failures.transform_values { |r| stored_review_failure(r) })
      @response.save!
    end
    release_review_claim!
    clear_stale_generation_error! if successes.any?
    log_review_diagnostics(@response, successes.keys) if successes.any?

    if failures.empty?
      redirect_to review_anchor, notice: t("flash.responses.review_ready")
    elsif successes.any?
      redirect_to review_anchor, notice: t("flash.responses.review_partial", reviewed: successes.size, total: missing.size,
                                             reason: review_failure_text(failures, :review_partial).brief)
    else
      redirect_to root_path, alert: review_failure_text(failures, :review).full
    end
  rescue ActiveRecord::RecordNotFound
    redirect_to root_path, alert: t("flash.responses.set_cleared_during_review")
  rescue AiService::Error => e
    release_review_claim!
    redirect_to root_path, alert: provider_failure_text(e, :review).full
  end

  # DELETE /responses/:id/start_over
  def start_over
    return redirect_to root_path, alert: t("flash.responses.start_over_after_review") if @response.reviewed?
    return redirect_to root_path, alert: t("flash.responses.start_over_not_today") unless @response.date == Date.current
    return redirect_to root_path, alert: t("flash.responses.start_over_while_reviewing") if @response.reviewing?

    @response.destroy
    redirect_to root_path, notice: t("flash.responses.answers_cleared")
  end

  def email_review
    return redirect_to root_path, alert: t("flash.responses.no_review_to_email") unless @response.fully_reviewed?

    ReviewMailer.send_review(@response).deliver_later
    redirect_to root_path, notice: t("flash.responses.review_emailed", email: current_user.email)
  end

  # POST /responses/:id/explain_differently
  def explain_differently
    existing = Array(@response.review_alternates[@section])
    if existing.size >= DailyResponse::MAX_ALTERNATES_PER_SECTION
      return render_section_error(t("errors.responses.alternates_used", count: DailyResponse::MAX_ALTERNATES_PER_SECTION))
    end

    alternate = AiService.for(current_user).explain_differently(
      current_user, @response.daily_exercise, @response,
      section: @section, prior_alternates: existing
    )

    capped = false
    remaining = nil
    @response.with_lock do
      current = Array(@response.review_alternates[@section])
      if current.size >= DailyResponse::MAX_ALTERNATES_PER_SECTION
        capped = true
      else
        @response.review_alternates = @response.review_alternates.merge(@section => current + [ alternate ])
        @response.save!
        remaining = DailyResponse::MAX_ALTERNATES_PER_SECTION - current.size - 1
      end
    end

    if capped
      render_section_error(t("errors.responses.alternates_used", count: DailyResponse::MAX_ALTERNATES_PER_SECTION))
    else
      render json: { status: "ok", alternate: alternate, remaining: remaining }
    end
  rescue AiService::Error => e
    render_provider_failure(e, :alternate)
  end

  def follow_ups
    question = UserText.clean(params[:question], limit: UserText::MAX_QUESTION_LENGTH).strip
    return render_section_error(t("errors.responses.question_blank")) if question.blank?

    asked = @response.review_follow_ups.where(section: @section, role: :user).count
    if asked >= DailyResponse::MAX_FOLLOW_UPS_PER_SECTION
      return render_section_error(t("review.follow_ups_used", count: DailyResponse::MAX_FOLLOW_UPS_PER_SECTION))
    end

    thread = @response.review_follow_ups.for_section(@section).map { |t| { role: t.role, content: t.content } }

    answer = AiService.for(current_user).answer_follow_up(
      current_user, @response.daily_exercise, @response,
      section: @section, question: question, thread: thread
    )

    capped = false
    remaining = nil
    @response.with_lock do
      current_count = @response.review_follow_ups.where(section: @section, role: :user).count
      if current_count >= DailyResponse::MAX_FOLLOW_UPS_PER_SECTION
        capped = true
      else
        @response.review_follow_ups.create!(section: @section, role: :user, content: question)
        @response.review_follow_ups.create!(section: @section, role: :assistant, content: answer)
        remaining = DailyResponse::MAX_FOLLOW_UPS_PER_SECTION - current_count - 1
      end
    end

    if capped
      render_section_error(t("review.follow_ups_used", count: DailyResponse::MAX_FOLLOW_UPS_PER_SECTION))
    else
      render json: { status: "ok", question: question, answer: answer, remaining: remaining }
    end
  rescue AiService::Error => e
    render_provider_failure(e, :follow_up)
  end

  # POST /responses/duck_thread
  def duck_thread
    exercise = current_user.daily_exercises.for_date.first
    return render json: { status: "error", error: t("errors.no_exercise_today") }, status: :not_found unless exercise

    section = params[:section].to_s
    return render_section_error(t("errors.section_not_in_exercise")) unless exercise.active_section_keys.include?(section)

    existing = current_user.daily_responses.find_by(daily_exercise: exercise, date: Date.current)
    return render_section_error(t("errors.responses.duck_after_submit")) if existing&.submitted?

    message = UserText.normalize(params[:message]).strip
    return render_section_error(t("errors.responses.message_blank")) if message.blank?
    if message.length > MAX_DUCK_MESSAGE_LENGTH
      return render_section_error(t("errors.responses.message_too_long", max: MAX_DUCK_MESSAGE_LENGTH))
    end

    thread = duck_thread_param
    if thread.size > MAX_DUCK_THREAD_ENTRIES ||
       thread.sum { |turn| turn[:content].bytesize } > MAX_DUCK_THREAD_BYTES
      return render_section_error(t("errors.responses.conversation_too_long"))
    end
    unless well_formed_thread?(thread)
      return render_section_error(t("errors.responses.conversation_out_of_step"))
    end
    if thread.count { |turn| turn[:role] == "user" } >= MAX_DUCK_TURNS_PER_SECTION
      return render_section_error(t("duck.turns_used", count: MAX_DUCK_TURNS_PER_SECTION))
    end

    answer = AiService.for(current_user).duck_response(
      current_user, exercise, section: section, message: message, thread: thread
    )

    render json: { status: "ok", answer: answer }
  rescue AiService::Error => e
    render_provider_failure(e, :duck)
  end

  # POST /responses/pseudocode_critique
  def pseudocode_critique
    return unless (context = load_pseudocode_context)

    row, section, pseudocode = context
    return render_section_error(critique_busy_message(row, section)) unless claim_pseudocode_round!(row, section, "critique", :critiqued?)

    result = AiService.for(current_user).critique_pseudocode(
      current_user, row.daily_exercise, section: section, pseudocode: pseudocode
    )

    write_pseudocode_round!(row, section, "critique",
      "initial_pseudocode" => pseudocode,
      "gaps_found"         => result[:gaps_found],
      "critique"           => result[:gaps],
      "critiqued_at"       => Time.current.iso8601)

    render json: { status: "ok", gaps_found: result[:gaps_found], gaps: result[:gaps] }
  rescue AiService::Error => e
    release_pseudocode_claim!(row, section, "critique")
    render_provider_failure(e, :critique)
  end

  private

  def stale_answer_sections(exercise)
    submitted = response_params[:answers]&.slice(*exercise.active_section_keys)
    return [] if submitted.blank?

    submitted.keys.map(&:to_s) - DailyResponse.normalize_answers(submitted, exercise).keys.map(&:to_s)
  end

  def save_answers_under_lock(exercise)
    ActiveRecord::Base.transaction do
      exercise.lock!
      next :stale if stale_answer_sections(exercise).any?

      @response = persisted_response_for(exercise)
      @response.lock!
      newly_submitted = false
      unless @response.submitted?
        assign_draft_response(exercise)
        newly_submitted = @response.submitted?
      end
      next :failed unless @response.save

      newly_submitted ? :newly_submitted : :saved
    end
  end

  def render_stale_answers
    respond_to do |format|
      format.json do
        render json: { status: "stale", errors: [ t("flash.responses.stale_answers") ] }, status: :conflict
      end
      format.html { redirect_to root_path, alert: t("flash.responses.stale_answers") }
    end
  end

  def assign_draft_response(exercise)
    submitted_answers = response_params[:answers]&.slice(*exercise.active_section_keys)
    submitted_answers = DailyResponse.normalize_answers(submitted_answers, exercise) if submitted_answers
    @response.assign_attributes(
      answers: @response.answers.merge(submitted_answers || {}).slice(*exercise.active_section_keys),
      submitted_at: response_params[:submit] == "1" ? Time.current : nil,
      concept_tags: exercise_concept_tags(exercise)
    )
    incoming_ratings = (response_params[:section_ratings] || {})
      .slice(*exercise.active_section_keys)
      .select { |_, value| DailyResponse::SELF_RATINGS.include?(value) }
    @response.section_ratings = @response.section_ratings.merge(incoming_ratings)
    if response_params[:submit] == "1"
      @response.section_ratings = @response.section_ratings.slice(*@response.answered_sections)
    end
  end

  def render_save_result(saved)
    respond_to do |format|
      format.json do
        if saved
          payload = { status: "saved", completeness: @response.completeness, submitted: @response.submitted? }
          payload[:review_url] = review_response_path(@response) if response_params[:submit] == "1"
          render json: payload
        else
          render json: { status: "error", errors: @response.errors.full_messages }, status: :unprocessable_content
        end
      end
      format.html do
        if saved
          redirect_to root_path
        else
          redirect_to root_path, alert: t("flash.responses.save_failed")
        end
      end
    end
  end

  def duck_thread_param
    Array(params[:thread]).first(MAX_DUCK_THREAD_ENTRIES + 1).filter_map { |turn|
      next unless turn.is_a?(Hash) || turn.respond_to?(:permit)

      role = turn[:role].to_s.downcase
      next unless %w[user assistant].include?(role)

      content = UserText.normalize(turn[:content])
      next if content.blank?

      { role: role, content: content }
    }
  end

  def well_formed_thread?(thread)
    return true if thread.empty?

    thread.last[:role] == "assistant" &&
      thread.each_slice(2).all? { |user_turn, assistant_turn|
        user_turn[:role] == "user" && assistant_turn&.dig(:role) == "assistant"
      }
  end

  def load_pseudocode_context
    exercise = current_user.daily_exercises.for_date.first
    unless exercise
      render json: { status: "error", error: t("errors.no_exercise_today") }, status: :not_found
      return
    end

    section = ExerciseSection::PseudocodeToCode.key
    return pseudocode_error(t("errors.responses.pseudocode.no_section")) unless exercise.active_section_keys.include?(section)

    pseudocode = validated_pseudocode or return
    row        = open_response_for(exercise) or return

    [ row, section, pseudocode ]
  end

  def validated_pseudocode
    value = UserText.normalize(params[:pseudocode]).strip
    return pseudocode_error(t("errors.responses.pseudocode.blank")) if value.blank?
    if value.length > ExerciseSection::PseudocodeToCode::MAX_PSEUDOCODE_LENGTH
      return pseudocode_error(t("errors.responses.pseudocode.too_long", max: ExerciseSection::PseudocodeToCode::MAX_PSEUDOCODE_LENGTH))
    end

    value
  end

  def open_response_for(exercise)
    row = persisted_response_for(exercise)
    return pseudocode_error(t("errors.responses.pseudocode.after_submit")) if row.submitted?

    row
  end

  def persisted_response_for(exercise)
    ActiveRecord::Base.transaction(requires_new: true) do
      current_user.daily_responses.find_or_create_by!(daily_exercise: exercise, date: Date.current)
    end
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
    current_user.daily_responses.find_by!(date: Date.current)
  end

  def claim_pseudocode_round!(row, section, phase, done)
    claimed = false

    row.with_lock do
      next if row.public_send(done, section) || row.pseudocode_claimed?(section, phase)

      row.merge_pseudocode_round!(section, "#{phase}_claimed_at" => Time.current.iso8601)
      claimed = true
    end

    claimed
  end

  def write_pseudocode_round!(row, section, phase, attrs)
    row.with_lock { row.merge_pseudocode_round!(section, attrs.merge("#{phase}_claimed_at" => nil)) }
  end

  def release_pseudocode_claim!(row, section, phase)
    return if row.nil?

    row.with_lock { row.merge_pseudocode_round!(section, "#{phase}_claimed_at" => nil) }
  end

  def critique_busy_message(row, section)
    t(row.critiqued?(section) ? "errors.responses.pseudocode.already_checked" : "errors.responses.pseudocode.check_running")
  end

  def pseudocode_error(message)
    render_section_error(message)
    nil
  end

  def review_anchor
    root_path(anchor: "ai-review")
  end

  def set_response
    @response = current_user.daily_responses.find(params[:id])
  end

  def require_reviewed_section!
    @section = params[:section].to_s
    return render_section_error(t("errors.section_not_in_exercise")) unless @response.daily_exercise.problem_set.key?(@section)
    render_section_error(t("errors.responses.no_review_yet")) unless @response.section_reviewed?(@section)
  end

  def render_section_error(message)
    render json: { status: "error", error: message }, status: :unprocessable_content
  end

  def claim_review!
    claimed = DailyResponse.where(id: @response.id)
                           .where("reviewing_since IS NULL OR reviewing_since < ?", DailyResponse::REVIEW_CLAIM_STALE_AFTER.ago)
                           .update_all(reviewing_since: Time.current) == 1
    @response.reload if claimed
    claimed
  end

  def release_review_claim!
    @response.update_column(:reviewing_since, nil)
  end

  def clear_stale_generation_error!
    current_user.clear_stale_generation_error!
  end

  def log_review_diagnostics(response, sections)
    payload = {
      event: "review",
      user_id: response.user_id,
      date: response.daily_exercise.date.to_s,
      sections: sections.index_with { |section|
        { ai_rating: response.ai_rating_for(section), self_rating: response.self_rating_for(section) }
      }
    }

    Rails.logger.info("[difficulty_diagnostics] #{payload.to_json}")
    log_pseudocode_review_diagnostics(response, sections)
  end

  def log_pseudocode_review_diagnostics(response, sections)
    section = ExerciseSection::PseudocodeToCode.key
    return unless sections.include?(section)

    critiqued = response.critiqued?(section)
    gaps      = ExerciseSection::PseudocodeToCode.normalize_critique(response.pseudocode_round(section)["critique"]).size
    missed    = DailyResponse.review_points(graded_missed(response.ai_review&.dig(section))).size

    Rails.logger.info(
      "[pseudocode] user=#{response.user_id} date=#{response.daily_exercise.date} phase=review " \
      "critiqued=#{critiqued} gaps=#{gaps} missed=#{missed} " \
      "disagreement=#{critiqued && gaps.zero? && missed.positive?}"
    )
  end

  def graded_missed(review)
    return nil unless review.is_a?(Hash)

    review.dig(ReviewProseVerdict::ORIGINAL_KEY, "missed") || review["missed"]
  end

  def review_failure_text(failures, surface)
    kind    = failures.values.map { |f| f[:failure] }.tally.max_by { |_, count| count }.first
    example = failures.values.find { |f| f[:failure] == kind }
    ProviderFailureText.new(kind, provider: example[:provider] || current_user.provider, surface: surface,
                            failed_at: example[:failed_at] || Time.current, zone: current_user.effective_time_zone,
                            retry_after: example[:retry_after], variant: ProviderFailureText.variant_for(current_user))
  end

  def stored_review_failure(result)
    { "kind" => result[:failure], "provider" => result[:provider], "quota_id" => result[:quota_id],
      "retry_after" => result[:retry_after], "at" => (result[:failed_at] || Time.current).iso8601 }.compact
  end

  def response_params
    @response_params ||= params.require(:response).permit(
      :submit,
      answers: ExerciseSection.keys,
      section_ratings: ExerciseSection.keys
    )
  end

  def exercise_concept_tags(exercise)
    exercise.active_section_keys
      .index_with { |section| exercise.problem_set.dig(section, "concept") }
      .compact
  end

  def enqueue_concept_references(exercise)
    enqueued = []
    exercise_concept_tags(exercise).each do |section, concept|
      next if concept == "other"
      language = ConceptBucket.for(section, exercise.language)
      pair = [ concept, language ]
      next if enqueued.include?(pair) || ConceptReference.exists?(concept: concept, language: language)
      GenerateConceptReferenceJob.perform_later(concept: concept, language: language, user_id: current_user.id)
      enqueued << pair
    end
  end
end
