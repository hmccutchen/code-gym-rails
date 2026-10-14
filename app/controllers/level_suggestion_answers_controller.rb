class LevelSuggestionAnswersController < ApplicationController
  # POST /level_suggestion/answer
  def create
    # An Apply that graduates the last junior kind ends the track, and its count arrives after.
    return render(json: { answered: current_user.track_proposals_answered }) unless current_user.on_learning_track?

    User.update_counters(current_user.id, track_proposals_answered: 1)
    render json: { answered: current_user.reload.track_proposals_answered }
  end
end
