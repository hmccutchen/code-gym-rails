# Design notes: docs/code-notes/app/controllers/profile_controller.md
class ProfileController < ApplicationController
  include ExerciseMixLadders

  skip_before_action :require_provider

  # PATCH /profile
  def update
    outcome = ProfileUpdate.new(current_user, params).save

    case outcome.status
    when :saved then render json: saved_body
    when :stale then render_stale_preferences(outcome)
    when :invalid then render_json_error(outcome.error, status: :unprocessable_content)
    else raise ArgumentError, "Unhandled profile update outcome: #{outcome.status}"
    end
  end

  # POST /profile/track_preview
  def track_preview
    value = params[:user]
    unless value.is_a?(ActionController::Parameters) && value.keys == [ "skill_level" ] && User::SKILL_LEVELS.include?(value[:skill_level])
      return render_json_error(t("tracks.preview.invalid_level"), status: :unprocessable_content)
    end

    change = TrackChange.new(levels: current_user.section_kind_levels, locked: current_user.locked_section_kinds,
                             from: current_user.skill_level, to: value[:skill_level])
    render json: track_body.merge(
      kind_rungs: current_user.kind_rungs, already_saved: change.already_saved?,
      preview_html: render_to_string(partial: "api_keys/track_preview", formats: [ :html ], locals: { change: change }),
      track_change: { from: change.from, to: change.to, preferences_version: current_user.section_kind_preferences_version }
    )
  end

  private

  def render_stale_preferences(outcome)
    render_json_error(t("exercise_mix.conflict"), status: :conflict, current: preference_state,
                                                  skill_level: current_user.skill_level,
                                                  daily_kinds: DailyKinds.for(current_user).map(&:key),
                                                  layout_changed: outcome.layout_changed)
  end

  def preference_state
    {
      section_kind_weights:             current_user.section_kind_weights,
      excluded_section_kinds:           current_user.excluded_section_kinds & rendered_exclusions,
      section_kind_levels:              current_user.section_kind_levels,
      locked_section_kinds:             current_user.locked_section_kinds,
      section_kind_preferences_version: current_user.section_kind_preferences_version,
      ladder_preparation:               ladder_preparation
    }
  end

  def rendered_exclusions = ExerciseSection.rotatable(daily: DailyKinds.for(current_user)).map(&:key)

  def saved_body
    body = { time_zone: current_user.time_zone,
             daily_section_count: current_user.daily_section_count }
    body.merge!(daily_kinds: DailyKinds.for(current_user).map(&:key), rotates: DailyKinds.rotates?(current_user)) if daily_sections_update?
    return body unless preference_update? || track_update?

    body.merge(section_kind_preferences_version: current_user.section_kind_preferences_version,
               ladder_preparation: ladder_preparation, kind_rungs: current_user.kind_rungs, **(track_update? ? track_body : {}))
  end

  def track_update? = params.require(:user).key?(:skill_level)

  def daily_sections_update? = params.require(:user).slice(:daily_section_count, :daily_section_kinds).present?

  def track_body
    { skill_level: current_user.skill_level, preferences: preference_state, kept_own_level: kept_own_level }
  end

  def kept_own_level
    kept = current_user.section_kind_levels.map do |kind, level|
      key = current_user.locked_section_kinds.include?(kind) ? "tracks.kept_locked_section" : "tracks.kept_section"
      t(key, name: t("sections.#{kind}.name"), level: t("exercise_mix.levels.#{level}"))
    end
    kept.empty? ? "" : t("tracks.kept_own_level", sections: kept.to_sentence)
  end

  def preference_update?
    user_params = params.require(:user)
    ProfileUpdate::PREFERENCE_KEYS.any? { |key| user_params.key?(key) }
  end
end
