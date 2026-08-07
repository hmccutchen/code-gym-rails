# The one section whose question is "design something", so its answer has
# predictable parts — the approach, the shape of the interface, and what could
# go wrong. The template names those parts so the blank textarea stops being
# the hard part. It is not a required structure: nothing validates against it
# beyond ignoring untouched labels when measuring an answer's substance.
class ExerciseSection::Pattern < ExerciseSection
  # Fallback only. The generator returns an `answer_scaffold` tailored to the
  # day's actual question; this is what a pattern answer needs in general, used
  # for rows generated before the field existed and for a provider that omits
  # or mangles it.
  DEFAULT_SCAFFOLD = [
    "Your approach:",
    "Interface — how would this be called:",
    "What would be easy to get wrong or worth testing:"
  ].freeze

  def self.default_scaffold
    DEFAULT_SCAFFOLD
  end
end
