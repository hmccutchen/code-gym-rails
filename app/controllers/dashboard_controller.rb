class DashboardController < ApplicationController
  def show
    @exercise = current_user.daily_exercises.for_date.first
    @response = @exercise&.daily_response ||
                @exercise && DailyResponse.new(user: current_user, daily_exercise: @exercise, date: Date.current)

    if @exercise&.regenerating?
      @generating = true
      return
    end

    @regeneration_failed = @exercise.present? && current_user.last_generation_error_date == Date.current

    return unless @exercise.nil? && current_user.api_key_present? && current_user.api_key_present?

    if flash[:generating]
      # Set by DailyExercisesController#generate right after a manual weekend
      # trigger or a "Try again" retry — an explicit fresh trigger always
      # takes priority over a stale failure recorded earlier today.
      @generating = true
    elsif current_user.last_generation_error_date == Date.current
      # An earlier attempt today failed and nothing has retried since — show
      # the failure instead of silently auto-enqueuing another attempt.
      @generation_failed = true
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
    exercise = current_user.daily_exercises.for_date.first

    if exercise&.regenerating?
      render json: { status: "pending" }
    elsif exercise
      render json: { status: "ready" }
    elsif current_user.last_generation_error_date == Date.current
      render json: { status: "failed", message: current_user.last_generation_error }
    else
      render json: { status: "pending" }
    end
  end
end
