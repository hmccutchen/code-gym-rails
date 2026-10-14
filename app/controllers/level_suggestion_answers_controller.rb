class LevelSuggestionAnswersController < ApplicationController
  # POST /level_suggestion/answer
  def create
    User.update_counters(current_user.id, track_proposals_answered: 1)
    render json: { answered: current_user.reload.track_proposals_answered }
  end
end
