class LevelSuggestionDismissalsController < ApplicationController
  ACTIONS_BY_REASON = { "not_now" => "dismissed", "removed" => "removed" }.freeze

  # Evidence can age before the lock; never move a current-level cutoff back.
  def create
    return head(:not_found) unless current_user.on_learning_track?
    return render_json_error(t("level_suggestion.card.invalid_steps"), status: :unprocessable_content) if invalid_steps?

    evidence = LevelSuggestion::Evidence.for(current_user)
    outcome = nil
    current_user.with_lock { outcome = record_cutoffs(params[:kinds], evidence) }

    case outcome
    when :not_found then head(:not_found)
    when :invalid then render_json_error(t("level_suggestion.card.invalid"), status: :unprocessable_content)
    when :stale then render_json_error(t("level_suggestion.card.stale"), status: :conflict)
    else render json: { dismissed: params[:kinds] }
    end
  end

  private

  # Kinds set aside from the card's removable list arrive after Apply changed the proposal, so validate current targets.
  def record_cutoffs(kinds, evidence)
    return :not_found unless current_user.on_learning_track?

    action = ACTIONS_BY_REASON[params.fetch(:reason, "not_now")]
    return :invalid unless action && valid_kinds?(kinds)
    return :stale if shown_steps.to_a.any? { |step| rungs[step.kind] != step.from }

    through = evidence.newest_date || Date.current
    advancing = kinds.uniq.select { |kind| existing_cutoff(kind).nil? || existing_cutoff(kind) < through }
    current_user.level_suggestion_events.create!(
      LevelSuggestionEvent.dismissal_rows(current_user, kinds: advancing, action: action, results: evidence.results,
                                                        shown: shown_steps.to_a.to_h { |step| [ step.kind, step.to ] })
    )
    current_user.update!(level_suggestion_cutoffs: current_user.level_suggestion_cutoffs.merge(
      kinds.index_with { |kind| cutoff_for(kind, through) }
    ))
    :ok
  end

  def existing_cutoff(kind)
    LevelSuggestion.cutoff_date(current_user.level_suggestion_cutoffs[kind], level: rungs[kind])
  end

  def cutoff_for(kind, through)
    { "level" => rungs[kind], "through" => [ existing_cutoff(kind), through ].compact.max.iso8601 }
  end

  def valid_kinds?(kinds)
    kinds.is_a?(Array) && kinds.any? && kinds.all? do |kind|
      kind.is_a?(String) && ExerciseSection.keys.include?(kind) &&
        LevelSuggestion::LADDER.include?(rungs[kind])
    end
  end

  def rungs
    @rungs ||= current_user.kind_rungs
  end

  def shown_steps
    return if params[:steps].nil?

    @shown_steps ||= LevelSuggestionStep.parse_all(params[:steps])
  end

  def invalid_steps?
    return false if params[:steps].nil?

    shown_steps.nil? || !params[:kinds].is_a?(Array) || (shown_steps.map(&:kind) - params[:kinds]).any?
  end
end
