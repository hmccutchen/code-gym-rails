module NoteQuestion
  SIGNALLED_RULES = %w[cleared duck_turns too_hard skipped].freeze
  NO_SIGNAL = "hardest".freeze

  Pick = Data.define(:rule, :section) do
    def key = section ? "#{rule}:#{section}" : rule
  end

  def self.pick(sections:, cleared:, duck_turns:, too_hard:, skipped:)
    signals = SIGNALLED_RULES.zip([ cleared, duck_turns, too_hard, skipped ])
    signals.each do |rule, signalled|
      section = sections.find { |key| signalled.include?(key) }
      return Pick.new(rule: rule, section: section) if section
    end
    Pick.new(rule: NO_SIGNAL, section: nil)
  end

  def self.parse(stored)
    return Pick.new(rule: NO_SIGNAL, section: nil) if stored == NO_SIGNAL

    rule, section = stored.to_s.split(":", 2)
    Pick.new(rule: rule, section: section) if SIGNALLED_RULES.include?(rule) && ExerciseSection.keys.include?(section)
  end

  def self.text(pick)
    kind = I18n.t("sections.#{pick.section}.name") if pick.section
    I18n.t("learner_questions.note.#{pick.rule}", kind: kind)
  end
end
