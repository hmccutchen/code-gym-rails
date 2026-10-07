# Every module whose hand-written words reach a Learn page or a section's
# glossary hover. Generated lessons are held to AiService::PLAIN_LANGUAGE_STANDARD
# through their prompt; text written into the code has no prompt, so
# spec/models/hand_written_learn_text_spec.rb holds each module listed here to
# the standard's checkable rules instead. A new module of static reader-facing
# text joins this list and answers .learn_text with a hash of id => text.
module HandWrittenLearnText
  MODULES = [ Glossary, ConceptBookSources, LearnLessons ].freeze

  def self.learn_text
    MODULES.map(&:learn_text).reduce({}, :merge)
  end
end
