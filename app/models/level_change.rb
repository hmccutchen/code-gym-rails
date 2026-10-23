# Design notes: docs/code-notes/app/models/level_change.md
class LevelChange
  def initialize(user, first_choice:, shown:)
    @user = user
    @first_choice = first_choice
    @shown = shown
    @before = { levels: user.section_kind_levels_in_database || {}, skill_level: user.skill_level_in_database }
    @cutoffs_before = user.level_suggestion_cutoffs_in_database || {}
  end

  def clear_track_targets
    return if @first_choice || !@user.skill_level_changed?

    @track_change = TrackChange.new(levels: @user.section_kind_levels, locked: @user.locked_section_kinds,
                                    from: @before[:skill_level], to: @user.skill_level)
    @user.section_kind_levels = @track_change.levels
  end

  def record_cutoffs
    return if @first_choice

    before_rungs = KindDifficulty.new(levels: @before[:levels], locked: []).rungs(skill_level: @before[:skill_level])
    moved = @user.kind_rungs.select { |kind, rung| before_rungs[kind] != rung && LevelSuggestion::LADDER.include?(rung) }
    return if moved.empty?

    through = Time.use_zone(@user.effective_time_zone) { Date.current }.iso8601
    @user.level_suggestion_cutoffs = @user.level_suggestion_cutoffs.merge(
      moved.to_h { |kind, rung| [ kind, { "level" => rung, "through" => through } ] }
    )
  end

  def write_events
    return true if @first_choice || !(@user.saved_change_to_section_kind_levels? || @user.saved_change_to_skill_level?)

    @user.level_suggestion_events.create!(LevelSuggestionEvent.applied_rows(
      @user,
      before: @before,
      after: { levels: @user.section_kind_levels, skill_level: @user.skill_level },
      shown: @shown, cutoffs: @cutoffs_before, cleared: @track_change&.cleared || []
    ))
    true
  end
end
