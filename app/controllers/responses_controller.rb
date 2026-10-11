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
    outcome = ResponseReview.new(@response, user: current_user).call

    case outcome.status
    when :not_submitted    then redirect_to root_path, alert: t("flash.responses.not_submitted")
    when :already_reviewed then redirect_to review_anchor, notice: t("flash.responses.already_reviewed")
    when :busy             then redirect_to root_path, alert: t("flash.responses.review_already_running")
    when :set_cleared      then redirect_to root_path, alert: t("flash.responses.set_cleared_during_review")
    when :provider_error   then redirect_to root_path, alert: provider_failure_text(outcome.error, :review).full
    when :ready            then redirect_to review_anchor, notice: t("flash.responses.review_ready")
    when :partial          then redirect_to review_anchor, notice: partial_review_notice(outcome)
    when :failed           then redirect_to root_path, alert: review_failure_text(outcome.failures, :review).full
    else raise ArgumentError, "Unhandled review outcome: #{outcome.status.inspect}"
    end
  end

  # DELETE /responses/:id/start_over
  def start_over
    blocker = @response.replace_blocker
    return redirect_to root_path, alert: t("flash.responses.start_over_after_review") if blocker == :reviewed
    return redirect_to root_path, alert: t("flash.responses.start_over_not_today") unless @response.date == Date.current
    return redirect_to root_path, alert: t("flash.responses.start_over_while_reviewing") if blocker == :reviewing

    @response.destroy
    redirect_to root_path, notice: t("flash.responses.answers_cleared")
  end

  # POST /responses/:id/email_review
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

  # POST /responses/:id/follow_ups
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
    return render_json_error(t("errors.no_exercise_today"), status: :not_found) unless exercise

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
    exercise.with_response_locked do |locked|
      next :stale if stale_answer_sections(exercise).any?

      @response = locked || persisted_response_for(exercise).lock!
      newly_submitted = false
      unless @response.submitted?
        assign_draft_response(exercise)
        newly_submitted = @response.submitted?
      end
      raise ActiveRecord::Rollback if newly_submitted && refuse_unsubmittable
      next :failed unless @response.save

      newly_submitted ? :newly_submitted : :saved
    end || :failed
  end

  def refuse_unsubmittable
    blocker = @response.submit_blocker
    @response.errors.add(:base, t("dashboard.exercise.submit_nudges.#{blocker}")) if blocker
    blocker
  end

  def render_stale_answers
    respond_to do |format|
      format.json do
        render_json_error(t("flash.responses.stale_answers"), status: :conflict, outcome: "stale")
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

  def submit_state
    { answered_sections: @response.answered_sections, submit_blocker: @response.submit_blocker,
      section_statuses: @response.section_keys.index_with { |key| helpers.section_status(@response, key) } }
  end

  def render_save_result(saved)
    respond_to do |format|
      format.json do
        if saved
          payload = { status: "saved", completeness: @response.completeness, submitted: @response.submitted?, **submit_state }
          payload[:review_url] = review_response_path(@response) if response_params[:submit] == "1"
          render json: payload
        else
          render_json_error(@response.errors.full_messages.to_sentence, status: :unprocessable_content, **submit_state)
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
      render_json_error(t("errors.no_exercise_today"), status: :not_found)
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
    render_json_error(message, status: :unprocessable_content)
  end

  def partial_review_notice(outcome)
    t("flash.responses.review_partial", reviewed: outcome.successes.size, total: outcome.missing.size,
                                        reason: review_failure_text(outcome.failures, :review_partial).brief)
  end

  def review_failure_text(failures, surface)
    kind    = failures.values.map { |f| f[:failure] }.tally.max_by { |_, count| count }.first
    example = failures.values.find { |f| f[:failure] == kind }
    ProviderFailureText.new(kind, provider: example[:provider] || current_user.provider, surface: surface,
                            failed_at: example[:failed_at] || Time.current, zone: current_user.effective_time_zone,
                            retry_after: example[:retry_after], variant: ProviderFailureText.variant_for(current_user))
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
