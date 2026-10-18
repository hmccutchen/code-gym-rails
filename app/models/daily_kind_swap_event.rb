# Design notes: docs/code-notes/app/models/daily_kind_swap_event.md
class DailyKindSwapEvent < ApplicationRecord
  self.table_name = "daily_kind_swaps"

  belongs_to :user

  TODAY_SECTIONS = %w[unanswered answered submitted not_in_set no_set].freeze
  NO_SET = "no_set".freeze

  validates :place, numericality: { only_integer: true, in: 0...DailyKinds::COUNT }
  validates :from_kind, :to_kind, inclusion: { in: ->(_) { ExerciseSection.keys } }
  validates :today_section, inclusion: { in: TODAY_SECTIONS }
  validates :planned_size, absence: true, if: -> { today_section == NO_SET }
  validates :planned_size, numericality: { only_integer: true }, allow_nil: true
  validates :size_setting, inclusion: { in: User::DAILY_SECTION_COUNTS }, allow_nil: true
end
