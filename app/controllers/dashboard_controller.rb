class DashboardController < ApplicationController
  # no-store, or Back after submit → review replays the cached empty form with a Submit button that re-posts it.
  before_action :no_store, only: :show

  def show
    return redirect_to(welcome_path) if current_user.first_run?

    # Rendered in every state; #status does not ask, since a pick is not generation progress.
    @featured = ConceptReference.featured

    # Re-read after the move: a second first-load of the day can lose the race and move nothing.
    @exercise = current_user.daily_exercises.for_date.first
    if @exercise.nil?
      current_user.carry_held_set_forward!
      @exercise = current_user.daily_exercises.for_date.first
    end
    @response = @exercise&.daily_response ||
                @exercise && DailyResponse.new(user: current_user, daily_exercise: @exercise, date: Date.current)
    @track_proposal = TrackGraduation.for(current_user) if current_user.on_learning_track? && @response&.submitted?
    @size_change = SizeForecast.for(current_user, @exercise) if @response&.submitted?

    @trial_status = TrialStatus.for(current_user) if current_user.on_trial?

    if @exercise&.regenerating?
      @generating = true
      return
    end

    @regeneration_failed = @exercise.present? && current_user.last_generation_error_date == Date.current

    return unless @exercise.nil?

    if current_user.trial_ended?
      @trial_ended = true
      return
    end
    return unless current_user.provider_ready?

    if flash[:generating]
      # A fresh manual trigger outranks a failure recorded earlier today.
      @generating = true
    elsif current_user.last_generation_error_date == Date.current
      @generation_failed = true
    elsif Date.current.on_weekend?
      # Ahead of the pause check: a weekend is empty either way, so naming the pause would mislead.
      @weekend_no_exercise = true
    elsif current_user.paused_generation_at?
      # Opening the dashboard is not a request for a set; the paused state renders the button back in.
      @generation_paused = true
    else
      GenerateDailyExercisesJob.perform_later(user_id: current_user.id)
      @generating = true
    end
  end

  # GET /dashboard/status — polled by dashboard/_generating, since this app loads no Turbo or Stimulus JS.
  def status
    exercise = current_user.daily_exercises.for_date.first

    if exercise&.regenerating?
      render json: { status: "pending" }
    elsif exercise
      render json: { status: "ready" }
    elsif current_user.last_generation_error_date == Date.current
      render json: { status: "failed", message: current_user.generation_failure_message(surface: :generation) }
    else
      render json: { status: "pending" }
    end
  end
end
