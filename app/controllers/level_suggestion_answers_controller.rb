class LevelSuggestionAnswersController < ApplicationController
  # POST /level_suggestion/answer
  def create
    User.update_counters(current_user.id, level_suggestion_answers: 1)
    render json: { answered: current_user.reload.level_suggestion_answers }
  end
end
