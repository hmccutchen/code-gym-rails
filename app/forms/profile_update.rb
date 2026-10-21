# Design notes: docs/code-notes/app/forms/profile_update.md
class ProfileUpdate
  Outcome = Data.define(:status, :error, :layout_changed) do
    def self.of(status, error: nil, layout_changed: false)
      new(status: status, error: error, layout_changed: layout_changed)
    end
  end

  PREFERENCE_KEYS = %i[section_kind_weights excluded_section_kinds section_kind_levels locked_section_kinds].freeze
  LOCKED_KEYS = %i[choose_track skill_level section_kind_levels].freeze
  TRACK_CHOICE_KEYS = %w[choose_track skill_level].freeze
  WHOLE_NUMBER = /\A\d+\z/

  def initialize(user, params)
    @user = user
    @params = params
    @user_params = params.require(:user)
  end

  def save
    error = shape_error
    return Outcome.of(:invalid, error: error) if error

    locked_save? ? save_under_lock : save_profile
  end

  private

  def posted?(key) = @user_params.key?(key)

  def shape_error
    return I18n.t("tracks.stale_page") if posted?(:learning_track)
    return daily_section_count_error unless daily_section_count_shaped?
    return "Section weights must map each section to a weight" unless object?(:section_kind_weights)
    return "Excluded section kinds must be a list of strings" unless list_of_strings?(:excluded_section_kinds)
    return "Section difficulty must map each section to a level" unless object?(:section_kind_levels)
    return "Locked section kinds must be a list of strings" unless list_of_strings?(:locked_section_kinds)
    return "Display preferences must use the listed options" unless object?(:display_preferences)
    return "Skill level must be one of #{User::SKILL_LEVELS.join(', ')}" unless skill_level_shaped?
    return "Change the track and the exercise mix in separate saves." if mixed_track_save?
    return "Level suggestions must be true or false" unless boolean?(:level_suggestions)

    I18n.t("level_suggestion.card.invalid_steps") if !@params[:level_suggestion_steps].nil? && shown_steps.nil?
  end

  # Active Record casts "" to nil, which reads as Automatic, so only a whole number or the word itself passes.
  def daily_section_count_shaped?
    return true unless posted?(:daily_section_count)

    value = @user_params[:daily_section_count]
    value.is_a?(Integer) || value == User::AUTOMATIC_SECTION_COUNT || (value.is_a?(String) && value.match?(WHOLE_NUMBER))
  end

  def daily_section_count_error
    "Daily sections must be #{User::AUTOMATIC_SECTION_COUNT} or one of #{User::DAILY_SECTION_COUNTS.to_a.join(', ')}"
  end

  # Checked on the raw param, since strong params drop a value of the wrong shape and the save would then return 200 without it.
  def object?(key) = !posted?(key) || @user_params[key].respond_to?(:to_unsafe_h)

  def list_of_strings?(key)
    return true unless posted?(key)

    list = @user_params[key]
    list.is_a?(Array) && list.all? { |entry| entry.is_a?(String) }
  end

  def boolean?(key) = !posted?(key) || [ true, false ].include?(@user_params[key])

  def skill_level_shaped?
    !posted?(:skill_level) || @user_params[:skill_level].nil? || @user_params[:skill_level].is_a?(String)
  end

  def mixed_track_save?
    posted?(:skill_level) && !posted?(:choose_track) && PREFERENCE_KEYS.any? { |key| posted?(key) }
  end

  def shown_steps
    return if @params[:level_suggestion_steps].nil?

    @shown_steps ||= LevelSuggestionStep.parse_all(@params[:level_suggestion_steps])
  end

  def locked_save?
    !@user_params[:section_kind_preferences_version].nil? || !shown_steps.nil? || !@params[:layout].nil? ||
      (LOCKED_KEYS | PREFERENCE_KEYS).any? { |key| posted?(key) }
  end

  # The track choice is checked after the lock reloads the user, since a choice bumps no version.
  def save_under_lock
    @user.with_lock do
      next Outcome.of(:invalid, error: "That track choice isn't available.") if invalid_track_choice?
      next Outcome.of(:stale, layout_changed: layout_moved?) if stale?
      next Outcome.of(:invalid, error: I18n.t("level_suggestion.card.invalid_steps")) if unsaved_shown_step?

      @user.choose_track(@user_params[:skill_level]) if track_choice?
      save_profile
    end
  end

  def track_choice? = posted?(:choose_track)

  def invalid_track_choice?
    return false unless track_choice?

    @user_params[:choose_track] != true || (@user_params.keys - TRACK_CHOICE_KEYS).any? ||
      LevelSuggestion::LADDER.exclude?(@user_params[:skill_level]) || !@user.first_run?
  end

  def stale?
    posted = @user_params[:section_kind_preferences_version]
    (!posted.nil? && posted.to_s != @user.section_kind_preferences_version.to_s) || moved_since_shown? || layout_moved?
  end

  def moved_since_shown?
    rungs = @user.kind_rungs
    shown_steps.to_a.any? { |step| rungs[step.kind] != step.from }
  end

  def layout_moved?
    !@params[:layout].nil? && Array(@params[:layout]) != DailyKinds.for(@user).map(&:key)
  end

  def unsaved_shown_step?
    levels = @user_params[:section_kind_levels]
    shown_steps.to_a.any? { |step| !levels.respond_to?(:to_unsafe_h) || levels.to_unsafe_h[step.kind] != step.to }
  end

  def save_profile
    saved = @user.transaction do
      level_change = LevelChange.new(@user, first_choice: track_choice?, shown: shown_moves)
      @user.assign_attributes(profile_attributes)
      level_change.clear_track_targets
      level_change.record_cutoffs
      @user.save && level_change.write_events
    end
    saved ? Outcome.of(:saved) : Outcome.of(:invalid, error: @user.errors.full_messages.to_sentence)
  end

  def shown_moves = shown_steps.to_a.to_h { |step| [ step.kind, step.to ] }

  def profile_attributes
    permitted = @user_params.permit(:name, :time_zone, :daily_section_count, :skill_level, :level_suggestions,
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
    @user.keep_unrendered_preferences(permitted.to_h)
  end
end
