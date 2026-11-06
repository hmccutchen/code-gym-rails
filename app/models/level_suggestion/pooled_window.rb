class LevelSuggestion
  # Design notes: docs/decisions/level-suggestions.md
  class PooledWindow
    Entry = Data.define(:kind, :result)

    # evidence maps each rotated kind at one rung to its results there, newest first.
    def initialize(evidence)
      entries = evidence.flat_map { |kind, results| results.map { |result| Entry.new(kind: kind, result: result) } }
      @entries = entries.each_with_index.sort_by { |entry, position| [ -entry.result.date.jd, position ] }
                        .first(WINDOW).map(&:first)
    end

    def favourable = @entries.count { |entry| entry.result.ai_favourable? }

    def passes? = @entries.size == WINDOW && favourable >= FAVOURABLE_NEEDED

    def carries?(kind)
      own = @entries.select { |entry| entry.kind == kind }

      own.any? && own.all? { |entry| entry.result.ai_favourable? }
    end
  end
end
