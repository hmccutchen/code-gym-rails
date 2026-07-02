class DashboardController < ApplicationController
  def show
    @exercise = current_user.daily_exercises.for_date.first
    @response = @exercise&.daily_response ||
                @exercise && DailyResponse.new(user: current_user, daily_exercise: @exercise, date: Date.current)

    # If no exercise exists yet today, check if we should trigger generation
    # (handles late arrivals / manual refresh — the cron handles the normal case)
    if @exercise.nil? && current_user.api_key_present?
      GenerateDailyExercisesJob.perform_later(user_id: current_user.id)
      @generating = true
    end
  end
end
