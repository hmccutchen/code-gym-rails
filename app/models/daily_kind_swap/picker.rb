# Design notes: docs/code-notes/app/models/daily_kind_swap/picker.md
class DailyKindSwap::Picker
  HINT_UNTIL_SUBMITTED_DAYS = 5

  Option = Data.define(:kind, :state, :note, :consequences, :mark) do
    def now? = state == :now
    def available? = state == :available
  end

  attr_reader :place, :current, :card_kind, :options, :closed

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
    @user      = user
    @place     = place
    @exercise  = exercise
    @hint      = hint
    @pair      = DailyKinds.for(user)
    @current   = @pair[place]
    @card_kind = exercise.daily_kinds[place]
    @closed    = closing_message
    @options   = @closed ? [] : ExerciseSection.all.map { |kind| option(kind) }
  end

  def hint? = @hint && !@closed

  def version = @user.section_kind_preferences_version

  def exercise_id = @exercise.id

  def draft_scope = @exercise.draft_scope

  def next_set_line
    I18n.t(@user.paused_generation_at? ? "daily_kinds.picker.next_set_paused" : "daily_kinds.picker.next_set")
  end

  def next_kind_line
    I18n.t("daily_kinds.picker.next_kind", kind: I18n.t("sections.#{@current.key}.name")) unless card_shows_current?
  end

  def card_shows_current? = @current == @card_kind

  def accent_mark?(option) = option.now? && card_shows_current?

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
    mark    = mark_for(kind, refusal)
    return Option.new(kind: kind, state: :now, note: nil, consequences: nil, mark: mark) if refusal == :unchanged
    return Option.new(kind: kind, state: :disabled, note: note(swap, refusal), consequences: nil, mark: mark) if refusal

    Option.new(kind: kind, state: :available, note: nil, consequences: consequences(kind), mark: mark)
  end

  def mark_for(kind, refusal)
    if kind == @current
      I18n.t(card_shows_current? ? "daily_kinds.picker.now" : "daily_kinds.picker.next_set_mark")
    elsif refusal == :already_daily
      I18n.t("daily_kinds.picker.already_daily")
    elsif kind == @card_kind
      I18n.t("daily_kinds.picker.today_mark")
    end
  end

  def note(swap, refusal)
    swap.refusal_message(refusal) unless refusal == :already_daily
  end

  def consequences(kind)
    DailyKindSwap::Consequences.for(pair: @pair, place: @place, kind: kind, preferences: preferences, day: day,
                                    languages: languages, pair_shares: pair_shares?)
  end

  def preferences = @preferences ||= KindPreferences.for(@user)

  def languages = @languages ||= ConceptBucket.language_buckets_for(@user.language)

  def day
    @day ||= DailyKindSwap::Consequences::Day.new(setting: @user.daily_section_count, planned_size: @exercise.planned_size,
                                                  brake: @exercise.planned_under_brake?)
  end

  def pair_shares?
    @pair_shares = DailyKindSwap::Consequences.shares_a_concept?(@pair, languages) if @pair_shares.nil?
    @pair_shares
  end
end
