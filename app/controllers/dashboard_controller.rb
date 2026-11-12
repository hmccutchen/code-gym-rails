class DashboardController < ApplicationController
  # no-store, or Back after submit → review replays the cached empty form with a Submit button that re-posts it.
  before_action :no_store, only: :show

  def show
    return redirect_to(welcome_path) if current_user.first_run?

    load_todays_set
    @automatic_pause = current_user.generation_paused_automatically?
    load_submitted_day_notes
    @trial_status = TrialStatus.for(current_user) if current_user.on_trial?
    @daily_kind_pickers = DailyKindSwap::Picker.for_day(current_user, exercise: @exercise, response: @response)

    return @content_state = :generating if @exercise&.regenerating?

    @exercise&.mark_opened!
    @regeneration_failed = @exercise.present? && current_user.generation_failed_today?
    @content_state = settle_missing_set if @exercise.nil?
  end

  # GET /dashboard/status — polled by dashboard/_generating.
  def status
    exercise = current_user.daily_exercises.for_date.first

    if exercise&.regenerating?
      render json: { status: "pending" }
    elsif exercise
      render json: { status: "ready" }
    elsif current_user.generation_failed_today?
      render json: { status: "failed", message: current_user.generation_failure_message(surface: :generation) }
    else
      render json: { status: "pending" }
    end
  end

  private

  def load_todays_set
    # Re-read after the move: a second first-load of the day can lose the race and move nothing.
    @exercise = current_user.daily_exercises.for_date.first
    if @exercise.nil?
      current_user.carry_held_set_forward!
      @exercise = current_user.daily_exercises.for_date.first
    end
    @response = @exercise&.daily_response&.tap { |stored| stored.user = current_user } ||
                @exercise && DailyResponse.new(user: current_user, daily_exercise: @exercise, date: Date.current)
  end

  def load_submitted_day_notes
    return unless @response&.submitted?

    @level_suggestion = LevelSuggestion.for(current_user) if current_user.suggests_level_moves?
    @size_change = SizeForecast.for(current_user, @exercise)
  end

  def settle_missing_set
    state = MissingSetState.for(
      trial_ended: current_user.trial_ended?, provider_ready: current_user.provider_ready?,
      manual_trigger: flash[:generating].present?, failed_today: current_user.generation_failed_today?,
      weekend: Date.current.on_weekend?, paused: current_user.paused_generation_at?
    )
    return state unless state == :start_generation

    GenerateDailyExercisesJob.perform_later(user_id: current_user.id)
    :generating
  end
end
