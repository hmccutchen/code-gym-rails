class ResponsesController < ApplicationController
  before_action :set_response, only: [ :review, :email_review ]

  # POST /responses — save answers (auto-save friendly, idempotent)
  def create
    exercise = current_user.daily_exercises.for_date.first
    return head :not_found unless exercise

    @response = current_user.daily_responses.find_or_initialize_by(
      daily_exercise: exercise,
      date: Date.current
    )

    # Only persist answers for sections this exercise actually has. Strong params
    # permit both `challenge` and `architecture` (the two possible third keys), so
    # without this a crafted request could store both and push
    # DailyResponse#answered_sections / #completeness past 3 sections / 100%.
    submitted_answers = response_params[:answers]&.slice(*exercise.problem_set.keys)

    @response.assign_attributes(
      answers:      submitted_answers.presence || @response.answers,
      submitted_at: response_params[:submit] == "1" ? Time.current : @response.submitted_at,
      concept_tags: exercise_concept_tags(exercise)
    )

    # Rating and notes ride along in the same autosave/submit payload as the
    # answers. A rating is only ever set, never cleared: the UI offers no way to
    # un-rate, and the autosave fires continuously — including from a stale tab
    # whose in-page state predates a rating saved elsewhere. Assigning only on a
    # valid enum value makes a saved rating unclearable by construction, and
    # sidesteps the ArgumentError an off-enum value would otherwise raise.
    rating = response_params[:rating].presence
    @response.legacy_rating = rating if rating && %w[too_easy right_level too_hard].include?(rating)
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
    return redirect_to history_anchor, notice: "Already reviewed." if @response.reviewed?

    ai_review = AiService.for(current_user).review_response(current_user, @response.daily_exercise, @response)

    @response.update!(ai_review: ai_review)
    redirect_to history_anchor, notice: "Review ready!"
  rescue AiService::AuthenticationError
    redirect_to root_path, alert: "Your API key was rejected — check it in Settings."
  rescue AiService::RateLimitError
    redirect_to root_path, alert: "The AI provider is rate-limiting requests — try again shortly."
  rescue AiService::Error => e
    redirect_to root_path, alert: "Couldn't generate the review: #{e.message}"
  end

  # POST /responses/:id/email_review — email the completed review to the user.
  # Both redirects go to root_path: the email button only ever renders on the
  # dashboard's submitted state (_submission.html.erb), not on history, so
  # that's the only page where the user can repeat or confirm the action.
  def email_review
    return redirect_to root_path, alert: "No review to email yet." unless @response.reviewed?

    ReviewMailer.send_review(@response).deliver_later
    redirect_to root_path, notice: "Review sent to #{current_user.email}."
  end

  private

  # Errors send the user back to the dashboard, where the retry button lives.
  # review's non-error redirects land on the history entry for the day in
  # question; email_review always goes to root_path (see above).
  def history_anchor
    history_path(anchor: "response-#{@response.id}")
  end

  def set_response
    @response = current_user.daily_responses.find(params[:id])
  end

  def response_params
    @response_params ||= params.require(:response).permit(
      :submit, :rating, :feedback_text, answers: [ :code_review, :pattern, :challenge, :architecture ]
    )
  end

  def exercise_concept_tags(exercise)
    %w[code_review pattern challenge architecture]
      .index_with { |section| exercise.problem_set.dig(section, "concept") }
      .compact
  end

  # Kick off generation for each distinct (concept, language-bucket) lacking a
  # cached reference. The architecture section is language-independent, so its
  # concept is bucketed under "architecture"; every other section uses the
  # exercise's language. The exists? check only avoids obvious no-op jobs; the
  # job re-checks, so a racing duplicate enqueue is harmless.
  def enqueue_concept_references(exercise)
    enqueued = []
    exercise_concept_tags(exercise).each do |section, concept|
      next if concept == "other"
      language = section == "architecture" ? "architecture" : exercise.language
      pair = [ concept, language ]
      next if enqueued.include?(pair) || ConceptReference.exists?(concept: concept, language: language)
      GenerateConceptReferenceJob.perform_later(concept: concept, language: language, user_id: current_user.id)
      enqueued << pair
    end
  end
end
