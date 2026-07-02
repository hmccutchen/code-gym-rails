class ResponsesController < ApplicationController
  before_action :set_response, only: [:feedback, :review]

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
      submitted_at: response_params[:submit] == "1" ? Time.current : @response.submitted_at
    )

    if @response.save
      render json: { status: "saved", completeness: @response.completeness }
    else
      render json: { status: "error", errors: @response.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # PATCH /responses/:id/feedback — rating + text after submission
  def feedback
    if @response.update(feedback_params)
      redirect_to root_path, notice: "Feedback saved — tomorrow's set will reflect this."
    else
      redirect_to root_path, alert: "Couldn't save feedback."
    end
  end

  # POST /responses/:id/review — trigger inline Claude review
  def review
    return redirect_to root_path, alert: "Submit your answers first." unless @response.submitted?
    return redirect_to root_path, notice: "Already reviewed." if @response.reviewed?

    service  = ClaudeService.new(current_user.api_key)
    ai_review = service.review_response(current_user, @response.daily_exercise, @response)

    @response.update!(ai_review: ai_review)
    redirect_to root_path, notice: "Review ready!"
  rescue ClaudeService::Error => e
    redirect_to root_path, alert: "Claude API error: #{e.message}"
  end

  private

  def set_response
    @response = current_user.daily_responses.find(params[:id])
  end

  def response_params
    params.require(:response).permit(:submit, answers: [:code_review, :pattern, :challenge])
  end

  def feedback_params
    params.require(:response).permit(:rating, :feedback_text)
  end
end
