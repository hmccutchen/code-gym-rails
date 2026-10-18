# Design notes: docs/code-notes/app/controllers/profile_controller.md
class ProfileController < ApplicationController
  include ExerciseMixLadders

  skip_before_action :require_provider

  # PATCH /profile
  def update
    return render_stale_track_page if params.require(:user).key?(:learning_track)
    return render_invalid_daily_section_count if invalid_daily_section_count?
    return render_invalid_weight    if invalid_section_kind_weights?
    return render_invalid_exclusion if invalid_excluded_section_kinds?
    return render_invalid_level     if invalid_section_kind_levels?
    return render_invalid_lock      if invalid_locked_section_kinds?
    return render_invalid_display   if invalid_display_preferences?
    return render_invalid_skill_level if invalid_skill_level?
    return render_mixed_track_save if mixed_track_save?
    return render_invalid_level_suggestions if invalid_level_suggestions?
    return render_invalid_shown_steps if invalid_shown_steps?

    saved = save_with_preference_precondition

    return render_stale_preferences if saved == :stale
    return render_invalid_track_choice if saved == :track_refused
    return render_invalid_shown_steps if saved == :unsaved_step

    if saved
      render json: saved_body
    else
      render_json_error(current_user.errors.full_messages.to_sentence, status: :unprocessable_content)
    end
  end

  private

  DAILY_SECTION_COUNT_STRINGS = User::DAILY_SECTION_COUNTS.map(&:to_s).freeze
  PREFERENCE_KEYS = %i[section_kind_weights excluded_section_kinds section_kind_levels locked_section_kinds].freeze
  LOCKED_KEYS = %i[choose_track skill_level section_kind_levels].freeze
  TRACK_CHOICE_KEYS = %w[choose_track skill_level].freeze

  def mixed_track_save?
    user_params = params.require(:user)
    user_params.key?(:skill_level) && !user_params.key?(:choose_track) && PREFERENCE_KEYS.any? { |key| user_params.key?(key) }
  end

  def render_mixed_track_save
    render_json_error("Change the track and the exercise mix in separate saves.", status: :unprocessable_content)
  end

  def invalid_daily_section_count?
    user_params = params.require(:user)
    return false unless user_params.key?(:daily_section_count)

    !valid_daily_section_count?(user_params[:daily_section_count])
  end

  def valid_daily_section_count?(value)
    return User::DAILY_SECTION_COUNTS.include?(value) if value.is_a?(Integer)

    value == User::AUTOMATIC_SECTION_COUNT || DAILY_SECTION_COUNT_STRINGS.include?(value)
  end

  def render_invalid_daily_section_count
    render_json_error("Daily sections must be #{User::AUTOMATIC_SECTION_COUNT} or one of #{User::DAILY_SECTION_COUNTS.to_a.join(', ')}", status: :unprocessable_content)
  end

  # Only an absent key skips: a wrong-shaped value would be dropped by strong params and return 200 having saved nothing.
  def invalid_section_kind_weights?
    user_params = params.require(:user)
    return false unless user_params.key?(:section_kind_weights)

    weights = user_params[:section_kind_weights]
    return true unless weights.respond_to?(:to_unsafe_h)

    weights.to_unsafe_h.values.any? { |value| !value.is_a?(Numeric) || KindPreferences::MULTIPLIERS.exclude?(value.to_f) }
  end

  def render_invalid_weight
    render_json_error("Section weight must be one of #{KindPreferences::MULTIPLIERS.join(', ')}", status: :unprocessable_content)
  end

  def invalid_excluded_section_kinds?
    invalid_string_list?(:excluded_section_kinds)
  end

  def invalid_locked_section_kinds?
    invalid_string_list?(:locked_section_kinds)
  end

  # Checked on the raw param: permit(key: []) drops non-scalar entries, so [{"a":1}] would clear the list with a 200.
  def invalid_string_list?(key)
    user_params = params.require(:user)
    return false unless user_params.key?(key)

    list = user_params[key]
    return true unless list.is_a?(Array)

    list.any? { |entry| !entry.is_a?(String) }
  end

  def render_invalid_exclusion
    render_json_error("Excluded section kinds must be a list of strings", status: :unprocessable_content)
  end

  def invalid_section_kind_levels?
    user_params = params.require(:user)
    return false unless user_params.key?(:section_kind_levels)

    levels = user_params[:section_kind_levels]
    return true unless levels.respond_to?(:to_unsafe_h)

    levels.to_unsafe_h.values.any? { |value| !value.is_a?(String) || KindDifficulty::LEVELS.exclude?(value) }
  end

  def render_invalid_level
    render_json_error("Section difficulty must be one of #{KindDifficulty::LEVELS.join(', ')}", status: :unprocessable_content)
  end

  def render_invalid_lock
    render_json_error("Locked section kinds must be a list of strings", status: :unprocessable_content)
  end

  def invalid_display_preferences?
    user_params = params.require(:user)
    return false unless user_params.key?(:display_preferences)

    values = user_params[:display_preferences]
    return true unless values.respond_to?(:to_unsafe_h)

    DisplayPreferences.problems_with(values.to_unsafe_h).any?
  end

  def render_invalid_display
    render_json_error("Display preferences must use the listed options", status: :unprocessable_content)
  end

  def invalid_skill_level?
    user_params = params.require(:user)

    user_params.key?(:skill_level) && User::SKILL_LEVELS.exclude?(user_params[:skill_level])
  end

  def render_invalid_skill_level
    render_json_error("Skill level must be one of #{User::SKILL_LEVELS.join(', ')}", status: :unprocessable_content)
  end

  def invalid_level_suggestions?
    user_params = params.require(:user)

    user_params.key?(:level_suggestions) && [ true, false ].exclude?(user_params[:level_suggestions])
  end

  def render_invalid_level_suggestions
    render_json_error("Level suggestions must be true or false", status: :unprocessable_content)
  end

  # Check and write under one row lock; the track choice is checked after reload, since a choice bumps no version.
  def save_with_preference_precondition
    user_params = params.require(:user)
    posted = user_params[:section_kind_preferences_version]
    return current_user.update(profile_params) unless locked_save?(user_params, posted)

    outcome = nil
    current_user.with_lock do
      outcome = if invalid_track_choice?(user_params)
        :track_refused
      elsif (!posted.nil? && posted.to_s != current_user.section_kind_preferences_version.to_s) || moved_since_shown?
        :stale
      elsif unsaved_shown_step?(user_params)
        :unsaved_step
      else
        current_user.shown_level_suggestions = shown_steps&.to_h { |step| [ step.kind, step.to ] }
        current_user.choose_track(user_params[:skill_level]) if user_params.key?(:choose_track)
        current_user.update(profile_params)
      end
    end
    outcome
  end

  def locked_save?(user_params, posted)
    !posted.nil? || !shown_steps.nil? || LOCKED_KEYS.any? { |key| user_params.key?(key) }
  end

  def shown_steps
    return if params[:level_suggestion_steps].nil?

    @shown_steps ||= LevelSuggestionStep.parse_all(params[:level_suggestion_steps])
  end

  def invalid_shown_steps? = !params[:level_suggestion_steps].nil? && shown_steps.nil?

  def render_invalid_shown_steps
    render_json_error(t("level_suggestion.card.invalid_steps"), status: :unprocessable_content)
  end

  def moved_since_shown?
    rungs = current_user.kind_rungs
    shown_steps.to_a.any? { |step| rungs[step.kind] != step.from }
  end

  def unsaved_shown_step?(user_params)
    levels = user_params[:section_kind_levels]
    shown_steps.to_a.any? { |step| !levels.respond_to?(:to_unsafe_h) || levels.to_unsafe_h[step.kind] != step.to }
  end

  def invalid_track_choice?(user_params)
    return false unless user_params.key?(:choose_track)

    user_params[:choose_track] != true || (user_params.keys - TRACK_CHOICE_KEYS).any? ||
      LevelSuggestion::LADDER.exclude?(user_params[:skill_level]) || !current_user.first_run?
  end

  def render_invalid_track_choice
    render_json_error("That track choice isn't available.", status: :unprocessable_content)
  end

  def render_stale_track_page
    render_json_error(t("tracks.stale_page"), status: :unprocessable_content)
  end

  def render_stale_preferences
    render_json_error(t("exercise_mix.conflict"), status: :conflict, current: preference_state)
  end

  def preference_state
    {
      section_kind_weights:             current_user.section_kind_weights,
      excluded_section_kinds:           current_user.excluded_section_kinds,
      section_kind_levels:              current_user.section_kind_levels,
      locked_section_kinds:             current_user.locked_section_kinds,
      section_kind_preferences_version: current_user.section_kind_preferences_version,
      ladder_preparation:               ladder_preparation
    }
  end

  def saved_body
    body = { name: current_user.name, time_zone: current_user.time_zone,
             daily_section_count: current_user.daily_section_count }
    return body unless preference_update? || track_update?

    body.merge(section_kind_preferences_version: current_user.section_kind_preferences_version,
               ladder_preparation: ladder_preparation, kind_rungs: current_user.kind_rungs, **track_body)
  end

  def track_update? = params.require(:user).key?(:skill_level)

  def track_body
    return {} unless track_update?

    { preferences: preference_state, kept_own_level: kept_own_level }
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
    PREFERENCE_KEYS.any? { |key| user_params.key?(key) }
  end

  def profile_params
    permitted = params.require(:user).permit(:name, :time_zone, :daily_section_count, :skill_level, :level_suggestions,
                                             section_kind_weights: {}, excluded_section_kinds: [],
                                             section_kind_levels: {}, locked_section_kinds: [],
                                             display_preferences: {})
    permitted[:name] = permitted[:name].to_s.strip if permitted.key?(:name)
    permitted[:time_zone] = permitted[:time_zone].to_s.strip.presence if permitted.key?(:time_zone)
    permitted[:daily_section_count] = nil if permitted[:daily_section_count] == User::AUTOMATIC_SECTION_COUNT
    # permit(x: {}) yields Parameters, which a jsonb column cannot serialize.
    %i[section_kind_weights section_kind_levels display_preferences].each do |key|
      permitted[key] = permitted[key].to_h if permitted.key?(key)
    end
    current_user.keep_daily_kind_entries(permitted.to_h)
  end
end
