# Design notes: docs/code-notes/app/models/level_suggestion_step.md
LevelSuggestionStep = Data.define(:kind, :from, :to) do
  def self.parse_all(raw)
    return unless raw.is_a?(Array) && raw.any? && raw.all? { |entry| entry.respond_to?(:to_unsafe_h) || entry.is_a?(Hash) }

    steps = raw.map { |entry| from_hash(entry.respond_to?(:to_unsafe_h) ? entry.to_unsafe_h : entry) }
    steps if steps.all?(&:one_rung?) && steps.map(&:kind).uniq.size == steps.size
  end

  def self.from_hash(entry)
    new(kind: entry["kind"], from: entry["from"], to: entry["to"])
  end

  def one_rung?
    ladder = LevelSuggestion::LADDER
    ExerciseSection.keys.include?(kind) && ladder.include?(from) && ladder.include?(to) &&
      (ladder.index(from) - ladder.index(to)).abs == 1
  end
end
