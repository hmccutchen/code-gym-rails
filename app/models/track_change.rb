# Design notes: docs/code-notes/app/models/track_change.md
class TrackChange
  attr_reader :levels, :cleared

  def initialize(levels:, locked:, from:, to:)
    @cleared = levels.select { |kind, level| [ from, to ].include?(level) && locked.exclude?(kind) }.keys
    @levels = levels.except(*@cleared)
  end
end
