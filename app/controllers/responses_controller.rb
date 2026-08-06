class ResponsesController < ApplicationController
  before_action :set_response, only: [ :review, :email_review, :self_explanation, :explain_differently, :follow_ups, :start_over ]
  before_action :require_reviewed_section!, only: [ :self_explanation, :explain_differently, :follow_ups ]

  # How long a claimed-but-unfinished review blocks a retry. The provider call
  # has no configured timeout, so a crash or hang mid-review must not lock the
  # user out forever — after this window a new request may reclaim the row.
  REVIEW_CLAIM_STALE_AFTER = 3.minutes

  # POST /responses — save answers (auto-save friendly, idempotent)
  def create
    exercise = current_user.daily_exercises.for_date.first
    return head :not_found unless exercise

    @response = current_user.daily_responses.find_or_initialize_by(
      daily_exercise: exercise,
      date: Date.current
    )

    # Only persist answers for sections this exercise actually has. Strong params
    # permit `challenge`, `architecture`, and `security_review` (the three possible
    # third keys), so without this a crafted request could store multiple and push
    # DailyResponse#answered_sections / #completeness past 3 sections / 100%.
    submitted_answers = response_params[:answers]&.slice(*exercise.problem_set.keys)

    @response.assign_attributes(
      answers:      submitted_answers.presence || @response.answers,
      submitted_at: response_params[:submit] == "1" ? Time.current : @response.submitted_at,
      concept_tags: exercise_concept_tags(exercise)
    )

    incoming_ratings = (response_params[:section_ratings] || {})
                         .slice(*exercise.problem_set.keys)
                         .select { |_, value| DailyResponse::SELF_RATINGS.include?(value) }
    @response.section_ratings = @response.section_ratings.merge(incoming_ratings)
    @response.feedback_text = response_params[:feedback_text] if response_params.key?(:feedback_text)

    saved = @response.save

    enqueue_concept_references(exercise) if saved && response_params[:submit] == "1"

    respond_to do |format|
      format.json do
        if saved
          payload = { status: "saved", completeness: @response.completeness }
          payload[:redirect] = root_path if response_params[:submit] == "1"
          render json: payload
        else
          render json: { status: "error", errors: @response.errors.full_messages }, status: :unprocessable_entity
        end
      end
      format.html do
        if saved
          redirect_to root_path
        else
          redirect_to root_path, alert: "Couldn't save your answers."
        end
      end
    end
  end

  # POST /responses/:id/review — trigger the inline AI review. Synchronous: the
  # request blocks for as long as the provider takes, then lands the user on the
  # history page anchored to the day they just had reviewed.
  def review
    return redirect_to root_path, alert: "Submit your answers first." unless @response.submitted?

    missing = @response.daily_exercise.problem_set.keys - Array(@response.ai_review&.keys)
    return redirect_to history_anchor, notice: "Already reviewed." if missing.empty?

    unless claim_review!
      return redirect_to root_path, alert: "A review is already being generated for this — check back in a moment."
    end

    # Recompute after reload to close the race: another request may have
    # finished the last missing section between our first check and the claim.
    missing = @response.daily_exercise.problem_set.keys - Array(@response.ai_review&.keys)
    if missing.empty?
      release_review_claim!
      return redirect_to history_anchor, notice: "Already reviewed."
    end

    first_batch = @response.ai_review.blank?
    results = AiService.for(current_user).review_sections(current_user, @response.daily_exercise, @response, sections: missing)
    successes = results.select { |_, r| r[:ok] }
    failures  = results.reject { |_, r| r[:ok] }

    ActiveRecord::Base.transaction do
      if successes.any?
        @response.ai_review = (@response.ai_review || {}).merge(successes.transform_values { |r| r[:review] })
        ConceptMastery.record_review!(@response, sections: successes.keys, apply_session_countdown: first_batch)
      end
      @response.review_errors = @response.review_errors
                                          .except(*successes.keys)
                                          .merge(failures.transform_values { |r| { "code" => r[:error_code], "message" => r[:message] } })
      @response.save!
    end
    release_review_claim!

    if failures.empty?
      redirect_to history_anchor, notice: "Review ready!"
    elsif successes.any?
      redirect_to root_path, notice: "#{successes.size} of #{missing.size} sections reviewed — #{failures.size} couldn't be reviewed, try again."
    else
      redirect_to root_path, alert: zero_success_alert(failures)
    end
  rescue AiService::AuthenticationError
    release_review_claim!
    redirect_to root_path, alert: "Your API key was rejected — check it in Settings."
  rescue AiService::RateLimitError
    release_review_claim!
    redirect_to root_path, alert: "The AI provider is rate-limiting requests — try again shortly."
  rescue AiService::Error => e
    release_review_claim!
    redirect_to root_path, alert: "Couldn't generate the review: #{e.message}"
  end

  # DELETE /responses/:id/start_over — abandon today's saved answers, ratings,
  # and feedback so the same problem set can be re-attempted from a blank
  # state. Destroys the row outright rather than clearing fields in place —
  # #create's find_or_initialize_by already handles a missing row cleanly, so
  # the next autosave just creates a fresh one with no special-casing needed
  # anywhere else. Hard-blocked once any section has been reviewed: from that
  # point ConceptMastery.record_review! has already moved real tier/streak
  # state for that concept, and this action has no way to undo that. Also
  # blocked while a review is actively claimed: #review's provider call runs
  # outside a transaction, so destroying the row mid-flight lets its
  # ConceptMastery writes commit against a response that no longer exists.
  def start_over
    return redirect_to root_path, alert: "This set has already been reviewed — nothing to start over." if @response.reviewed?
    return redirect_to root_path, alert: "You can only start over on today's set." unless @response.date == Date.current
    if @response.reviewing_since.present? && @response.reviewing_since > REVIEW_CLAIM_STALE_AFTER.ago
      return redirect_to root_path, alert: "A review is being generated for this — try again in a moment."
    end

    @response.destroy
    redirect_to root_path, notice: "Today's answers have been cleared — start fresh whenever you're ready."
  end

  # POST /responses/:id/email_review — email the completed review to the user.
  # Both redirects go to root_path: the email button only ever renders on the
  # dashboard's submitted state (_submission.html.erb), not on history, so
  # that's the only page where the user can repeat or confirm the action.
  def email_review
    return redirect_to root_path, alert: "No review to email yet." unless @response.fully_reviewed?

    ReviewMailer.send_review(@response).deliver_later
    redirect_to root_path, notice: "Review sent to #{current_user.email}."
  end

  # PATCH /responses/:id/self_explanation — save the user's own one-sentence
  # explanation of why a fix works. Capture only: nothing grades it, and it gates
  # nothing. Writing to an arbitrarily old response is intentional — /history is
  # where reviews live, so this is where the prompt is answered.
  def self_explanation
    text = params[:text].to_s.strip
    saved = true
    errors = nil

    # No AI call here, so the lock is held only for a fast read-merge-write —
    # unlike explain_differently/follow_ups there's nothing slow to keep
    # outside it. Without this, two tabs saving different sections at once
    # each hold their own stale in-memory hash, and the last save wins,
    # silently dropping the other tab's section.
    @response.with_lock do
      @response.self_explanations = @response.self_explanations.merge(
        @section => text
      )
      saved = @response.save
      errors = @response.errors.full_messages.to_sentence unless saved
    end

    if saved
      render json: { status: "saved" }
    else
      render_section_error(errors)
    end
  end

  # POST /responses/:id/explain_differently — one section's feedback, reframed.
  # Synchronous like #review; the caller posts via fetch and appends in place.
  def explain_differently
    existing = Array(@response.review_alternates[@section])
    if existing.size >= DailyResponse::MAX_ALTERNATES_PER_SECTION
      return render_section_error("You've already asked for #{DailyResponse::MAX_ALTERNATES_PER_SECTION} alternate explanations here.")
    end

    alternate = AiService.for(current_user).explain_differently(
      current_user, @response.daily_exercise, @response,
      section: @section, prior_alternates: existing
    )

    # The provider call above is slow and deliberately stays outside the lock.
    # The count check above is only advisory — two concurrent requests can both
    # read `existing.size` under the cap and both reach here. with_lock takes a
    # row lock and reloads @response, so this re-check is the real guarantee:
    # if the cap was reached by another request while this one was waiting on
    # the provider, this request backs off here instead of overwriting (and
    # silently dropping) the other request's alternate.
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
      render_section_error("You've already asked for #{DailyResponse::MAX_ALTERNATES_PER_SECTION} alternate explanations here.")
    else
      render json: { status: "ok", alternate: alternate, remaining: remaining }
    end
  rescue AiService::Error => e
    render json: { status: "error", error: e.message }, status: :service_unavailable
  end

  # POST /responses/:id/follow_ups — ask one clarifying question about a section's
  # review. Synchronous: a single short completion, so it needs no job or polling.
  # Both turns are written in one transaction, so a provider failure can never
  # leave an orphaned question with no answer in the thread.
  def follow_ups
    question = params[:question].to_s.strip
    return render_section_error("Ask a question first.") if question.blank?

    asked = @response.review_follow_ups.where(section: @section, role: :user).count
    if asked >= DailyResponse::MAX_FOLLOW_UPS_PER_SECTION
      return render_section_error("You've used all #{DailyResponse::MAX_FOLLOW_UPS_PER_SECTION} follow-ups for this section.")
    end

    thread = @response.review_follow_ups.for_section(@section).map { |t| { role: t.role, content: t.content } }

    answer = AiService.for(current_user).answer_follow_up(
      current_user, @response.daily_exercise, @response,
      section: @section, question: question, thread: thread
    )

    # The provider call above is slow and deliberately stays outside the lock.
    # The count check above is only advisory — two concurrent requests can both
    # read `asked == 2` and both reach here. with_lock takes a row lock and
    # reloads @response, so this re-check is the real guarantee: if the cap was
    # reached by another request while this one was waiting on the provider,
    # this request backs off here instead of writing a 4th turn.
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
      render_section_error("You've used all #{DailyResponse::MAX_FOLLOW_UPS_PER_SECTION} follow-ups for this section.")
    else
      render json: { status: "ok", answer: answer, remaining: remaining }
    end
  rescue AiService::Error => e
    render json: { status: "error", error: e.message }, status: :service_unavailable
  end

  private

  # Errors send the user back to the dashboard, where the retry button lives.
  # review's non-error redirects land on the history entry for the day in
  # question; email_review always goes to root_path (see above).
  #
  # History is paginated, so the anchor only resolves if the request lands on
  # the page holding that entry.
  def history_anchor
    history_page_path(@response.history_page, anchor: "response-#{@response.id}")
  end

  def set_response
    @response = current_user.daily_responses.find(params[:id])
  end

  # Shared by every endpoint that writes against an existing review. Ownership is
  # already enforced by set_response's association scope (another user's id raises
  # RecordNotFound → 404, which also avoids leaking whether that id exists); this
  # adds the two guards specific to review-attached writes. Validating the section
  # against the exercise's own problem_set mirrors #create's slice guard — without
  # it a crafted param writes arbitrary keys into the jsonb columns.
  def require_reviewed_section!
    @section = params[:section].to_s
    return render_section_error("That section isn't part of this exercise.") unless @response.daily_exercise.problem_set.key?(@section)
    render_section_error("No review to attach that to yet.") unless @response.section_reviewed?(@section)
  end

  def render_section_error(message)
    render json: { status: "error", error: message }, status: :unprocessable_entity
  end

  # Atomic claim against a concurrent double-review (e.g. an impatient second
  # click while the first request is still waiting on the provider): a single
  # UPDATE ... WHERE is serialized by Postgres row locking, so only one
  # concurrent caller can affect the row — the loser gets 0 rows and backs off
  # instead of racing into a second provider call and ConceptMastery write.
  def claim_review!
    claimed = DailyResponse.where(id: @response.id)
                           .where("reviewing_since IS NULL OR reviewing_since < ?", REVIEW_CLAIM_STALE_AFTER.ago)
                           .update_all(reviewing_since: Time.current) == 1
    @response.reload if claimed
    claimed
  end

  def release_review_claim!
    @response.update_column(:reviewing_since, nil)
  end

  def zero_success_alert(failures)
    codes = failures.values.map { |f| f[:error_code] }.uniq
    case codes
    in [ "authentication" ]
      "Your API key was rejected — check it in Settings."
    in [ "rate_limit" ]
      "The AI provider is rate-limiting requests — try again shortly."
    else
      "Couldn't generate the review: #{failures.values.first[:message]}"
    end
  end

  def response_params
    @response_params ||= params.require(:response).permit(
      :submit, :feedback_text,
      answers: ExerciseSection.keys,
      section_ratings: ExerciseSection.keys
    )
  end

  def exercise_concept_tags(exercise)
    ExerciseSection.keys
      .index_with { |section| exercise.problem_set.dig(section, "concept") }
      .compact
  end

  # Kick off generation for each distinct (concept, language-bucket) lacking a
  # cached reference. The exists? check only avoids obvious no-op jobs; the
  # job re-checks, so a racing duplicate enqueue is harmless.
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
