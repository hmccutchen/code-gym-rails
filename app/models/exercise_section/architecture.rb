# Language-independent by nature: an architecture concept transcends any one
# stack, so it draws from ARCHITECTURE_CONCEPTS rather than the day's language
# vocabulary. Its review carries no improved_code — the model is asked to return
# an empty string there, since a design decision has no single corrected form.
class ExerciseSection::Architecture < ExerciseSection
  # Fallback only — see ExerciseSection::Pattern::DEFAULT_SCAFFOLD.
  DEFAULT_SCAFFOLD = [
    "Which option, and why:",
    "Tradeoffs you considered:"
  ].freeze

  def self.default_scaffold
    DEFAULT_SCAFFOLD
  end

  def self.vocabulary_key
    :architecture
  end

  def self.improved_code?
    false
  end
end
