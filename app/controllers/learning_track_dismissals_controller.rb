class LearningTrackDismissalsController < ApplicationController
  # Read evidence before locking; merge into the reloaded user so a concurrent
  # level change or dismissal cannot lose its cutoff.
  def create
    return head(:not_found) unless current_user.on_learning_track?

    through = (TrackGraduation::Evidence.for(current_user).newest_date || Date.current).iso8601
    outcome = nil
    current_user.with_lock { outcome = record_cutoffs(params[:kinds], through) }

    case outcome
    when :not_found then head(:not_found)
    when :invalid then render json: { errors: [ t("learning_track.proposal.invalid") ] }, status: :unprocessable_content
    else render json: { dismissed: params[:kinds] }
    end
  end

  private

  # Removed bundle members arrive after Apply, when the proposal has changed.
  # Validate their current targets rather than membership in that proposal.
  def record_cutoffs(kinds, through)
    return :not_found unless current_user.on_learning_track?
    return :invalid unless valid_kinds?(kinds)

    levels = current_user.section_kind_levels
    current_user.update!(track_evidence_cutoffs: current_user.track_evidence_cutoffs.merge(
      kinds.index_with { |kind| { "level" => levels[kind], "through" => through } }
    ))
    :ok
  end

  def valid_kinds?(kinds)
    kinds.is_a?(Array) && kinds.any? && kinds.all? do |kind|
      kind.is_a?(String) && ExerciseSection.keys.include?(kind) &&
        LearningTrack::LEVELS.include?(current_user.section_kind_levels[kind])
    end
  end
end
