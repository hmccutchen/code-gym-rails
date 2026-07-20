class ResponsesController < ApplicationController
  before_action :set_response, only: [ :show, :feedback, :review, :email_review ]

  # POST /responses — save answers (auto-save friendly, idempotent)
  def create
    exercise = current_user.daily_exercises.for_date.first
    return head :not_found unless exercise

    @response = current_user.daily_responses.find_or_initialize_by(
      daily_exercise: exercise,
      date: Date.current
    )

    @response.assign_attributes(
      answers:      response_params[:answers] || @response.answers,
      submitted_at: response_params[:submit] == "1" ? Time.current : @response.submitted_at,
      concept_tags: exercise_concept_tags(exercise)
    )

    saved = @response.save

    enqueue_concept_references(exercise) if saved && response_params[:submit] == "1"

    respond_to do |format|
      format.json do
        if saved
          payload = { status: "saved", completeness: @response.completeness }
          payload[:redirect] = response_path(@response) if response_params[:submit] == "1"
          render json: payload
        else
          render json: { status: "error", errors: @response.errors.full_messages }, status: :unprocessable_entity
        end
      end
      format.html do
        if saved
          redirect_to(response_params[:submit] == "1" ? response_path(@response) : root_path)
        else
          redirect_to root_path, alert: "Couldn't save your answers."
        end
      end
    end
  end

  # GET /responses/:id — the dedicated single-day submission + review page.
  # Owner-scoped via set_response (current_user.daily_responses), so another
  # user's id raises RecordNotFound -> 404. Review stays manual/on-demand.
  def show
    return redirect_to root_path unless @response.submitted?
    @exercise = @response.daily_exercise
  end

  # PATCH /responses/:id/feedback — rating + text after submission
  def feedback
    if @response.update(feedback_params)
      redirect_to response_path(@response), notice: "Feedback saved — tomorrow's set will reflect this."
    else
      redirect_to response_path(@response), alert: "Couldn't save feedback."
    end
  end

  # POST /responses/:id/review — trigger inline Claude review
  def review
    return redirect_to response_path(@response), alert: "Submit your answers first." unless @response.submitted?
    return redirect_to response_path(@response), notice: "Already reviewed." if @response.reviewed?

    ai_review = AiService.for(current_user).review_response(current_user, @response.daily_exercise, @response)

    @response.update!(ai_review: ai_review)
    redirect_to response_path(@response), notice: "Review ready!"
  rescue AiService::AuthenticationError => e
    redirect_to response_path(@response), alert: "Your API key was rejected — check it in Settings. (#{e.message})"
  rescue AiService::RateLimitError => e
    redirect_to response_path(@response), alert: "The AI provider is rate-limiting requests — try again shortly."
  rescue AiService::Error => e
    redirect_to response_path(@response), alert: "Couldn't generate the review: #{e.message}"
  end

  # POST /responses/:id/email_review — email the completed review to the user
  def email_review
    return redirect_to response_path(@response), alert: "No review to email yet." unless @response.reviewed?

    ReviewMailer.send_review(@response).deliver_later
    redirect_to response_path(@response), notice: "Review sent to #{current_user.email}."
  end

  private

  def set_response
    @response = current_user.daily_responses.find(params[:id])
  end

  def response_params
    params.require(:response).permit(:submit, answers: [ :code_review, :pattern, :challenge ])
  end

  def feedback_params
    params.require(:response).permit(:rating, :feedback_text)
  end

  def exercise_concept_tags(exercise)
    %w[code_review pattern challenge]
      .index_with { |section| exercise.problem_set.dig(section, "concept") }
      .compact
  end

  # Kick off generation for each distinct concept lacking a cached reference.
  # The exists? check only avoids obvious no-op jobs; the job re-checks, so a
  # racing duplicate enqueue is harmless.
  def enqueue_concept_references(exercise)
    language = exercise.language
    concepts = exercise_concept_tags(exercise).values.uniq
    concepts.each do |concept|
      next if concept == "other"
      next if ConceptReference.exists?(concept: concept, language: language)
      GenerateConceptReferenceJob.perform_later(concept: concept, language: language, user_id: current_user.id)
    end
  end
end
