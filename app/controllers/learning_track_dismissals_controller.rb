class LearningTrackDismissalsController < ApplicationController
  ACTIONS_BY_REASON = { "not_now" => "dismissed", "removed" => "removed" }.freeze

  # Evidence can age before the lock; never move a current-level cutoff back.
  def create
    return head(:not_found) unless current_user.on_learning_track?

    evidence = TrackGraduation::Evidence.for(current_user)
    outcome = nil
    current_user.with_lock { outcome = record_cutoffs(params[:kinds], evidence) }

    case outcome
    when :not_found then head(:not_found)
    when :invalid then render_json_error(t("learning_track.proposal.invalid"), status: :unprocessable_content)
    else render json: { dismissed: params[:kinds] }
    end
  end

  private

  # Removed bundle members arrive after Apply changed the proposal, so validate current targets, not membership.
  def record_cutoffs(kinds, evidence)
    return :not_found unless current_user.on_learning_track?

    action = ACTIONS_BY_REASON[params.fetch(:reason, "not_now")]
    return :invalid unless action && valid_kinds?(kinds)

    current_user.level_suggestion_events.create!(
      LevelSuggestionEvent.dismissal_rows(current_user, kinds: kinds.uniq, action: action, results: evidence.results)
    )
    through = evidence.newest_date || Date.current
    current_user.update!(track_evidence_cutoffs: current_user.track_evidence_cutoffs.merge(
      kinds.index_with { |kind| cutoff_for(kind, through) }
    ))
    :ok
  end

  def cutoff_for(kind, through)
    level = current_user.section_kind_levels[kind]
    existing = TrackGraduation.cutoff_date(current_user.track_evidence_cutoffs[kind], level: level)
    { "level" => level, "through" => [ existing, through ].compact.max.iso8601 }
  end

  def valid_kinds?(kinds)
    kinds.is_a?(Array) && kinds.any? && kinds.all? do |kind|
      kind.is_a?(String) && ExerciseSection.keys.include?(kind) &&
        TrackGraduation::LADDER.include?(current_user.section_kind_levels[kind])
    end
  end
end
