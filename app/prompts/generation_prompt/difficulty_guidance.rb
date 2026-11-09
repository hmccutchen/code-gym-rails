# Design notes: docs/code-notes/app/prompts/generation_prompt/difficulty_guidance.md
module GenerationPrompt::DifficultyGuidance
  def self.render(rungs:, difficulty:, ladders:, mode: nil, assigned: false)
    locked, unlocked = rungs.keys.partition { |kind| difficulty.locked?(kind) }
    paragraphs = KindDifficulty::LEVELS.filter_map do |level|
      at_level = rungs.select { |_kind, rung| rung == level }.keys
      level_difficulty_paragraph(level, at_level, ladders, mode) if at_level.any?
    end

    [ "", "Difficulty by section. Each section's level overrides the profile's.",
      "Reasoning deepens within each kind's stated format and size limits, without unstated requirements.",
      "Concept ladders refine, never override, the applicable baseline and format.",
      *paragraphs, "",
      (assigned ? "Assigned retention checks stay at normal demand at that section's level." :
        "A retention check or established concept placed in one of these sections is pitched at that " \
        "section's level, with no easing."),
      (assigned ? "Follow the assigned practice instruction; keep locked sections at normal demand." : unlocked_difficulty_line(unlocked)),
      (locked_difficulty_line(locked) unless assigned) ].compact.join("\n")
  end

  def self.level_difficulty_paragraph(level, kinds, ladders, mode)
    definitions = kinds.index_with { |kind| kind.difficulty_definition(rung: level, mode: mode) }
    lines = [ "", "Sections at #{level}: #{kinds.map(&:key).join(', ')}" ]
    definitions.group_by { |_kind, definition| definition.rung }.each_value do |entries|
      lines << "Baseline: #{entries.first.last.standard}"
      lines.concat(entries.map { |kind, definition| "- #{kind.key}: #{definition.expectation}" })
      lines.concat(ladder_lines(entries.map(&:first), ladders))
    end
    lines.join("\n")
  end

  def self.ladder_lines(kinds, ladders)
    owners_by_entry = {}
    kinds.each do |kind|
      ladders.fetch(kind, {}).each do |entry|
        (owners_by_entry[entry] ||= []) << kind
      end
    end
    owners_by_entry.group_by { |_entry, owners| owners }.flat_map do |owners, entries|
      lines = entries.map(&:first).sort.map { |concept, text| "- #{concept}: #{text}" }
      [ "Concept ladders for #{owners.map(&:key).join(', ')}:", *lines ]
    end
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

  private_class_method :level_difficulty_paragraph, :ladder_lines, :unlocked_difficulty_line, :locked_difficulty_line
end
