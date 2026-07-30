# The vocabulary bucket a concept's history is recorded under. Architecture
# concepts are language-independent — they transcend any one stack, so they are
# tracked separately rather than under the day's generation language; every
# other section buckets under that language.
#
# Accepts one section or several: a concept tagged on multiple sections the same
# day belongs to the architecture bucket if any of them is the architecture
# section (see ConceptMastery.record_review!).
#
# A nil language passes through as a nil bucket — callers reading history for a
# response whose exercise is missing get no bucket rather than an exception.
class ConceptBucket
  ARCHITECTURE = "architecture".freeze

  def self.for(sections, language)
    Array(sections).any? { |section| section.to_s == ARCHITECTURE } ? ARCHITECTURE : language
  end
end
