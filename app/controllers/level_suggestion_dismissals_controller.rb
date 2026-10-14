class LevelSuggestionDismissalsController < ApplicationController
  ACTIONS_BY_REASON = { "not_now" => "dismissed", "removed" => "removed" }.freeze

  # Evidence can age before the lock; never move a current-level cutoff back.
  def create
    evidence = LevelSuggestion::Evidence.for(current_user)
    outcome = nil
    current_user.with_lock { outcome = record_cutoffs(params[:kinds], evidence) }

    case outcome
    when :invalid then render_json_error(t("learning_track.proposal.invalid"), status: :unprocessable_content)
    else render json: { dismissed: params[:kinds] }
    end
  end

  private

  # Kinds set aside from the card's removable list arrive after Apply changed the proposal, so validate current rungs.
  def record_cutoffs(kinds, evidence)
    action = ACTIONS_BY_REASON[params.fetch(:reason, "not_now")]
    return :invalid unless action && valid_kinds?(kinds)

    through = evidence.newest_date || Date.current
    advancing = kinds.uniq.select { |kind| existing_cutoff(kind).nil? || existing_cutoff(kind) < through }
    current_user.level_suggestion_events.create!(
      LevelSuggestionEvent.dismissal_rows(current_user, kinds: advancing, action: action, results: evidence.results)
    )
    current_user.update!(level_suggestion_cutoffs: current_user.level_suggestion_cutoffs.merge(
      kinds.index_with { |kind| cutoff_for(kind, through) }
    ))
    :ok
  end

  def existing_cutoff(kind)
    LevelSuggestion.cutoff_date(current_user.level_suggestion_cutoffs[kind], level: current_user.kind_rungs[kind])
  end

  def cutoff_for(kind, through)
    { "level" => current_user.kind_rungs[kind], "through" => [ existing_cutoff(kind), through ].compact.max.iso8601 }
  end

  def valid_kinds?(kinds)
    kinds.is_a?(Array) && kinds.any? && kinds.all? do |kind|
      kind.is_a?(String) && ExerciseSection.keys.include?(kind) &&
        LevelSuggestion::LADDER.include?(current_user.kind_rungs[kind])
    end
  end
end
