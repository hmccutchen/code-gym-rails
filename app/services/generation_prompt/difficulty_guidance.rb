module GenerationPrompt::DifficultyGuidance
  def self.render(rungs:, difficulty:, ladders:)
    locked, unlocked = rungs.keys.partition { |kind| difficulty.locked?(kind) }
    paragraphs = KindDifficulty::LEVELS.filter_map do |level|
      at_level = rungs.select { |_kind, rung| rung == level }.keys
      level_difficulty_paragraph(level, at_level, ladders.fetch(level, {})) if at_level.any?
    end

    [ "", "Difficulty by section. Pitch each section named below at its level; where it differs from the " \
          "skill level in the engineer profile above, the section's level wins.",
      *paragraphs, "",
      "A retention check or established concept placed in one of these sections is pitched at that " \
      "section's level, with no easing.",
      unlocked_difficulty_line(unlocked), locked_difficulty_line(locked) ].compact.join("\n")
  end

  def self.level_difficulty_paragraph(level, kinds, rungs)
    definition = KindDifficulty::LEVEL_DEFINITIONS.fetch(level)
    lines = [ "", "Sections at #{level}: #{kinds.map(&:key).join(', ')}" ]
    return (lines << "Pitch these problems at this level. A #{level} problem is: #{definition}").join("\n") if rungs.empty?

    lines << "Pitch these problems at this level for whichever concept you choose:"
    lines.concat(rungs.sort.map { |concept, rung| "- #{concept}: #{rung}" })
    (lines << "For a concept not listed, a #{level} problem is: #{definition}").join("\n")
  end

  def self.unlocked_difficulty_line(kinds)
    return if kinds.empty?

    "Unlocked (#{kinds.map(&:key).join(', ')}): tier annotations and rating adjustments above still apply to " \
      "these sections, eased or raised from the section's level rather than from the profile's skill level."
  end

  def self.locked_difficulty_line(kinds)
    return if kinds.empty?

    "Locked (#{kinds.map(&:key).join(', ')}): for these sections, ignore the `(reduced)` easing rule and both " \
      "the \"too easy\" and \"too hard\" rating adjustments above, whichever concept they carry — including a " \
      "concept the engineer has never seen. Where a locked section has an answer scaffold or starter code, " \
      "write it at its level, not easier."
  end

  private_class_method :level_difficulty_paragraph, :unlocked_difficulty_line, :locked_difficulty_line
end
