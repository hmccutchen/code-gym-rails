# Design notes: docs/code-notes/app/models/daily_sections_choice.md
class DailySectionsChoice
  attr_reader :pair

  def initialize(user)
    @places = DailyKinds.normalize(user.daily_section_kinds)
    @pair   = DailyKinds.pair_of(user.daily_section_kinds)
  end

  def counts = User::DAILY_SECTION_COUNTS.to_a - [ DailyKinds::COUNT ]

  def single?(count) = count < DailyKinds::COUNT

  def keeping(kind) = ([ kind ] + (@places - [ kind ])).map(&:key)

  def options = ExerciseSection.all.reject { |kind| DailyKinds.conflict(kind, @pair) }

  def extras_for(count)
    (DailyKinds::COUNT...count).each_with_object([]) do |place, chosen|
      stored = @places[place]
      chosen << (fits?(stored, chosen) ? stored : options.find { |kind| fits?(kind, chosen) })
    end
  end

  private

  def fits?(kind, chosen) = !kind.nil? && options.include?(kind) && DailyKinds.conflict(kind, @pair + chosen).nil?
end
