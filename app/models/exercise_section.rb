# The kinds of section a daily problem set can hold. Each kind is a named class
# rather than a bare string so the facets that vary per kind — which vocabulary
# its concept is validated against, whether its review can carry improved_code,
# whether it can occupy the rolled third slot — live in one place instead of
# being re-derived by a conditional at each call site.
#
# Deliberately closed, like the concept vocabularies these select: adding a kind
# means adding a subclass here, not persisting a new string.
class ExerciseSection
  # Enumeration order, matching the order these keys have always been listed in
  # (strong params, concept tagging, scenario collection) so anything deriving a
  # Hash or Array from it keeps the ordering it already had.
  def self.all
    [ CodeReview, Pattern, Challenge, Architecture, SecurityReview ]
  end

  def self.keys
    all.map(&:key)
  end

  # Precedence order, NOT enumeration order: a problem_set holding more than one
  # third key (a provider returning both) resolves the way it always has —
  # architecture first, then security_review, then challenge.
  def self.thirds
    [ Architecture, SecurityReview, Challenge ]
  end

  # nil for anything outside the closed set. Callers decide what an unrecognized
  # section means; a provider can put arbitrary keys in a jsonb payload, so this
  # never raises.
  def self.find(key)
    all.find { |section| section.key == key.to_s }
  end

  class << self
    def key
      name.demodulize.underscore
    end

    def third?
      ExerciseSection.thirds.include?(self)
    end

    # Names which vocabulary this kind's concept is validated against. AiService
    # owns the constants themselves — this only says which one applies, so the
    # vocabularies stay closed Ruby constants in one place.
    def vocabulary_key
      :concepts
    end

    # Whether a review of this kind can carry corrected code.
    def improved_code?
      true
    end
  end
end
