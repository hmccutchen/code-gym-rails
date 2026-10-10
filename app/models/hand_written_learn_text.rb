# Static reader-facing text has no prompt, so hand_written_learn_text_spec holds each module here to the plain-language rules.
module HandWrittenLearnText
  MODULES = [ Glossary, ConceptBookSources, LearnLessons ].freeze

  def self.learn_text
    MODULES.map(&:learn_text).reduce({}, :merge)
  end
end
