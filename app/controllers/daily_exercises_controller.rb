class DailyExercisesController < ApplicationController
  # POST /regenerate — manually re-run today's exercise generation, capped
  # at once per day via regenerated_at. Replaces the existing DailyExercise
  # row's contents in place; never creates a second row for the same day.
  def regenerate
    exercise = current_user.daily_exercises.for_date.first
    return redirect_to root_path, alert: "No exercise set to regenerate yet." unless exercise

    if exercise.regenerated_at.present?
      return redirect_to root_path, alert: "You've already generated a new set today."
    end

    problem_set = AiService.for(current_user).generate_exercise(current_user, language: exercise.language)

    ActiveRecord::Base.transaction do
      exercise.daily_response&.destroy
      exercise.update!(
        problem_set:    problem_set,
        generated_at:   Time.current,
        regenerated_at: Time.current
      )
    end

    redirect_to root_path, notice: "New set generated!"
  rescue AiService::Error => e
    redirect_to root_path, alert: "Couldn't generate a new set: #{e.message}"
  end
end
