# Design notes: docs/code-notes/app/controllers/profile_controller.md
class ProfileController < ApplicationController
  include ExerciseMixLadders

  skip_before_action :require_provider

  def update
    return render_invalid_daily_section_count if invalid_daily_section_count?
    return render_invalid_weight    if invalid_section_kind_weights?
    return render_invalid_exclusion if invalid_excluded_section_kinds?
    return render_invalid_level     if invalid_section_kind_levels?
    return render_invalid_lock      if invalid_locked_section_kinds?
    return render_invalid_display   if invalid_display_preferences?
    return render_invalid_skill_level if invalid_skill_level?

    saved = save_with_preference_precondition

    return render_stale_preferences if saved == :stale
    return render_invalid_learning_track if saved == :track_refused

    if saved
      render json: saved_body
    else
      render json: { errors: current_user.errors.full_messages },
             status: :unprocessable_content
    end
  end

  private

  DAILY_SECTION_COUNT_STRINGS = User::DAILY_SECTION_COUNTS.map(&:to_s).freeze
  PREFERENCE_KEYS = %i[section_kind_weights excluded_section_kinds section_kind_levels locked_section_kinds].freeze

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
    render json: { errors: [ "Daily sections must be #{User::AUTOMATIC_SECTION_COUNT} or one of #{User::DAILY_SECTION_COUNTS.to_a.join(', ')}" ] },
           status: :unprocessable_content
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
    render json: { errors: [ "Section weight must be one of #{KindPreferences::MULTIPLIERS.join(', ')}" ] },
           status: :unprocessable_content
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
    render json: { errors: [ "Excluded section kinds must be a list of strings" ] },
           status: :unprocessable_content
  end

  def invalid_section_kind_levels?
    user_params = params.require(:user)
    return false unless user_params.key?(:section_kind_levels)

    levels = user_params[:section_kind_levels]
    return true unless levels.respond_to?(:to_unsafe_h)

    levels.to_unsafe_h.values.any? { |value| !value.is_a?(String) || KindDifficulty::LEVELS.exclude?(value) }
  end

  def render_invalid_level
    render json: { errors: [ "Section difficulty must be one of #{KindDifficulty::LEVELS.join(', ')}" ] },
           status: :unprocessable_content
  end

  def render_invalid_lock
    render json: { errors: [ "Locked section kinds must be a list of strings" ] },
           status: :unprocessable_content
  end

  def invalid_display_preferences?
    user_params = params.require(:user)
    return false unless user_params.key?(:display_preferences)

    values = user_params[:display_preferences]
    return true unless values.respond_to?(:to_unsafe_h)

    DisplayPreferences.problems_with(values.to_unsafe_h).any?
  end

  def render_invalid_display
    render json: { errors: [ "Display preferences must use the listed options" ] },
           status: :unprocessable_content
  end

  def invalid_skill_level?
    user_params = params.require(:user)

    user_params.key?(:skill_level) && User::SKILL_LEVELS.exclude?(user_params[:skill_level])
  end

  def render_invalid_skill_level
    render json: { errors: [ "Skill level must be one of #{User::SKILL_LEVELS.join(', ')}" ] },
           status: :unprocessable_content
  end

  # Check and write under one row lock; the track choice is checked after reload, since Experienced bumps no version.
  def save_with_preference_precondition
    user_params = params.require(:user)
    posted = user_params[:section_kind_preferences_version]
    return current_user.update(profile_params) if posted.nil? && !user_params.key?(:learning_track)

    outcome = nil
    current_user.with_lock do
      outcome = if invalid_learning_track_change?(user_params)
        :track_refused
      elsif !posted.nil? && posted.to_s != current_user.section_kind_preferences_version.to_s
        :stale
      else
        current_user.update(profile_params)
      end
    end
    outcome
  end

  TRACK_CHOICE_KEYS = {
    LearningTrack::ON  => %w[learning_track section_kind_levels skill_level section_kind_preferences_version],
    LearningTrack::OFF => %w[learning_track]
  }.freeze

  def invalid_learning_track_change?(user_params)
    return false unless user_params.key?(:learning_track)
    return true unless current_user.learning_track_change_allowed?(user_params[:learning_track])
    return true if (user_params.keys - TRACK_CHOICE_KEYS.fetch(user_params[:learning_track])).any?
    return false unless user_params[:learning_track] == LearningTrack::ON
    return true if user_params[:section_kind_preferences_version].nil?
    return true unless user_params[:skill_level] == LearningTrack::START_SKILL_LEVEL

    levels = user_params[:section_kind_levels]
    !levels.respond_to?(:to_unsafe_h) || levels.to_unsafe_h != LearningTrack.preset_levels
  end

  def render_invalid_learning_track
    render json: { errors: [ "That learning track change isn't available." ] },
           status: :unprocessable_content
  end

  def render_stale_preferences
    render json: {
      errors: [ t("exercise_mix.conflict") ],
      current: {
        section_kind_weights:             current_user.section_kind_weights,
        excluded_section_kinds:           current_user.excluded_section_kinds,
        section_kind_levels:              current_user.section_kind_levels,
        locked_section_kinds:             current_user.locked_section_kinds,
        section_kind_preferences_version: current_user.section_kind_preferences_version,
        ladder_preparation:               ladder_preparation
      }
    }, status: :conflict
  end

  def saved_body
    body = { name: current_user.name, time_zone: current_user.time_zone,
             daily_section_count: current_user.daily_section_count }
    return body unless preference_update?

    body.merge(section_kind_preferences_version: current_user.section_kind_preferences_version,
               ladder_preparation: ladder_preparation)
  end

  def preference_update?
    user_params = params.require(:user)
    PREFERENCE_KEYS.any? { |key| user_params.key?(key) }
  end

  def profile_params
    permitted = params.require(:user).permit(:name, :time_zone, :daily_section_count, :learning_track, :skill_level,
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
    permitted
  end
end
