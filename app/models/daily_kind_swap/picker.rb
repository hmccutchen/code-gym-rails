# Design notes: docs/code-notes/app/models/daily_kind_swap/picker.md
class DailyKindSwap::Picker
  HINT_UNTIL_SUBMITTED_DAYS = 5

  Option = Data.define(:kind, :state, :note, :consequences) do
    def now? = state == :now
    def available? = state == :available
  end

  attr_reader :place, :current, :options

  # Keyed by card: membership in the row's pair, never position, so a dropped daily section moves no control.
  def self.for_day(user, exercise:, response:)
    return {} if exercise.nil?

    delivered = exercise.active_section_keys
    cards     = exercise.daily_kinds.each_with_index.select { |kind, _place| delivered.include?(kind.key) }
    hint_at   = cards.first&.last if hint?(user, response)

    cards.to_h { |kind, place| [ kind.key, new(user, place: place, exercise: exercise, hint: place == hint_at) ] }
  end

  def self.hint?(user, response)
    return false if response&.submitted?

    user.daily_kind_swap_events.none? &&
      user.daily_responses.where.not(submitted_at: nil).count < HINT_UNTIL_SUBMITTED_DAYS
  end
  private_class_method :hint?

  def initialize(user, place:, exercise:, hint: false)
    @user     = user
    @place    = place
    @exercise = exercise
    @hint     = hint
    @pair     = DailyKinds.for(user)
    @current  = @pair[place]
    @closed   = closing_message
    @options  = @closed ? [] : ExerciseSection.all.map { |kind| option(kind) }
  end

  attr_reader :closed

  def hint? = @hint && !@closed

  def version = @user.section_kind_preferences_version

  def next_set_line
    I18n.t(@user.paused_generation_at? ? "daily_kinds.picker.next_set_paused" : "daily_kinds.picker.next_set")
  end

  private

  # A refusal of the place's own kind is about the account, not a choice, so the picker offers nothing.
  def closing_message
    swap = DailyKindSwap.new(@user, place: @place, kind: @current.key, version: nil)
    reason = swap.refusal
    swap.refusal_message(reason) unless reason.nil? || reason == :unchanged
  end

  def option(kind)
    swap    = DailyKindSwap.new(@user, place: @place, kind: kind.key, version: nil)
    refusal = swap.refusal
    return Option.new(kind: kind, state: :now, note: nil, consequences: nil) if refusal == :unchanged
    return Option.new(kind: kind, state: :disabled, note: note(swap, refusal), consequences: nil) if refusal

    Option.new(kind: kind, state: :available, note: nil, consequences: consequences(kind))
  end

  def note(swap, refusal)
    refusal == :already_daily ? I18n.t("daily_kinds.picker.already_daily") : swap.refusal_message(refusal)
  end

  def consequences(kind)
    @preferences ||= KindPreferences.for(@user)
    DailyKindSwap::Consequences.for(pair: @pair, place: @place, kind: kind, preferences: @preferences,
                                    setting: @user.daily_section_count, planned_size: @exercise.plan_notes["size"],
                                    languages: ConceptBucket.language_buckets_for(@user.language))
  end
end
