class DashboardController < ApplicationController
  def show
    @exercise = current_user.daily_exercises.for_date.first
    @response = @exercise&.daily_response ||
                @exercise && DailyResponse.new(user: current_user, daily_exercise: @exercise, date: Date.current)

    return unless @exercise.nil? && current_user.api_key_present?

    if flash[:generating]
      # Set by DailyExercisesController#generate right after a manual weekend
      # trigger — avoids re-enqueueing a second job on this same request.
      @generating = true
    elsif Date.current.on_weekday?
      GenerateDailyExercisesJob.perform_later(user_id: current_user.id)
      @generating = true
    else
      @weekend_no_exercise = true
    end
  end

  # GET /dashboard/status — polled by dashboard/_generating's inline script
  # while an async generation job is in flight, so the page can detect
  # completion (or failure) without a live Turbo/ActionCable connection
  # (this app loads no Turbo/Stimulus JS).
  def status
    if current_user.daily_exercises.for_date.exists?
      render json: { status: "ready" }
    elsif current_user.last_generation_error_date == Date.current
      render json: { status: "failed", message: current_user.last_generation_error }
    else
      render json: { status: "pending" }
    end
  end
end
