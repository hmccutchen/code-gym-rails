# Design notes: docs/code-notes/app/models/daily_kind_swap.md
class DailyKindSwap
  Outcome = Data.define(:status, :reason, :message, :want_it_today, :daily_kinds, :version)

  CONFLICT_REASONS = { repeat: :already_daily, second_fourth: :second_fourth }.freeze

  def self.call(user, place:, kind:, version:)
    new(user, place: place, kind: kind, version: version).call
  end

  def self.refusal(user, place:, kind:)
    new(user, place: place, kind: kind, version: nil).refusal
  end

  def initialize(user, place:, kind:, version:)
    @user    = user
    @place   = Integer(place.to_s, 10, exception: false)
    @kind    = ExerciseSection.find(kind.to_s)
    @version = version
  end

  def call
    @user.with_lock do
      reason = shape_refusal || (:stale if stale?) || pair_refusal
      next outcome(:refused, reason) if reason

      save!
      outcome(:saved)
    end
  rescue ActiveRecord::RecordInvalid => error
    Rails.logger.warn("[daily_kind_swap] user=#{@user.id} refused=#{error.record.class} on=#{error.record.errors.attribute_names.join(",")}")
    @user.reload
    outcome(:refused, :invalid)
  end

  def refusal = shape_refusal || pair_refusal

  def refusal_message(reason) = message(:refused, reason)

  private

  def pair_refusal
    return :unchanged if current[@place] == @kind

    conflict = DailyKinds.conflict(@kind, current.reject.with_index { |_kind, index| index == @place })
    return CONFLICT_REASONS.fetch(conflict) if conflict

    :empties_a_slot if @user.emptied_slots(daily: proposed).any?
  end

  def shape_refusal
    return :trial_ended if @user.trial_ended?
    return :invalid_place unless DailyKinds.place?(@place)

    :unknown_kind unless @kind
  end

  def stale? = @version.to_s != @user.section_kind_preferences_version.to_s

  def current = @current ||= DailyKinds.for(@user)

  def proposed = current.dup.tap { |kinds| kinds[@place] = @kind }

  def save!
    from = current[@place].key
    @user.update!(daily_section_kinds: DailyKinds.stored(proposed.map(&:key)))
    @user.daily_kind_swap_events.create!(place: @place, from_kind: from, to_kind: @kind.key,
                                         today_section: today_section(from), planned_size: exercise&.planned_size,
                                         size_setting: @user.daily_section_count)
  end

  def today_section(from)
    return DailyKindSwapEvent::NO_SET if exercise.nil?
    return "not_in_set" if exercise.active_section_keys.exclude?(from)
    return "submitted" if response&.submitted?

    response&.answered?(from) ? "answered" : "unanswered"
  end

  def exercise = @exercise ||= @user.daily_exercises.for_date.first

  def response = exercise&.daily_response

  def outcome(status, reason = nil)
    Outcome.new(status: status, reason: reason, message: message(status, reason), want_it_today: want_it_today(status),
                daily_kinds: DailyKinds.for(@user).map(&:key), version: @user.section_kind_preferences_version)
  end

  def message(status, reason)
    return I18n.t(@user.paused_generation_at? ? "daily_kinds.swap.saved_paused" : "daily_kinds.swap.saved") if status == :saved

    I18n.t("daily_kinds.swap.refused.#{reason}", **refusal_details(reason))
  end

  def refusal_details(reason)
    case reason
    when :second_fourth  then { kinds: names(ExerciseSection.fourths) }
    when :empties_a_slot then { kinds: names(@user.emptied_slots(daily: proposed).values.flatten) }
    else {}
    end
  end

  def names(kinds) = kinds.map { |kind| I18n.t("sections.#{kind.key}.name") }.to_sentence(last_word_connector: " and ")

  def want_it_today(status)
    return unless status == :saved && exercise&.regeneration_offered?(response) && !response&.submitted?

    I18n.t("daily_kinds.swap.want_it_today")
  end
end
