# One generated piece per recognition group on how to look for that kind of
# problem, cached once for the whole team the way ConceptReference is. It
# teaches a process for recognizing a category, never an answer, so it is shown
# to everyone with no exposure gating (see AiService::RECOGNITION_GUIDE_SCOPE).
#
# A recognition group is a named ConceptGroup or a language-independent bucket,
# whose concepts render as one flat list and so already form a single group. A
# language bucket's core group has no shared identity to teach and gets none.
class RecognitionGuide < ApplicationRecord
  GROUP_KEYS = (ConceptGroup::NAMED.map(&:first) + ConceptBucket::LANGUAGE_INDEPENDENT).freeze

  # What each named group is about, for the prompt. A language-independent
  # bucket already states this as its LANGUAGE_CONFIG focus, so it is read from
  # there rather than written twice.
  NAMED_GROUP_SUBJECTS = {
    "data_modeling"      => "flaws in how data is structured and stored: tables, keys, constraints, indexes, and the migrations that change them.",
    "domain_modeling"    => "whether the model's names match the words the business uses, and which things must change together behind one entry point.",
    "silent_correctness" => "defects that survive every normal check: the code runs, nothing raises, no validator fires, and the output is wrong anyway.",
    "meta_skill"         => "reading code before judging it: what it is for, what it quietly assumes, and whether a problem you can see is the cause or only a symptom.",
    "code_smell"         => "shapes in code that signal a design problem before any bug appears.",
    "oo_design"          => "design principles: rules for how responsibilities and dependencies between classes should run.",
    "module_design"      => "what a module's interface costs every caller, compared with how much the module hides."
  }.freeze

  # The meta-skill concepts are already process concepts, so a generic "how to
  # recognize this category" piece would repeat their own references.
  FRAMINGS = {
    "meta_skill" => "These concepts are reasoning skills the app tracks one by one, not kinds of defect. " \
                    "Frame this piece as the one habit they exercise together, reading code carefully before " \
                    "judging it, and show how they fit into a single pass. Leave each concept's detail to its own reference."
  }.freeze

  validates :group_key, presence: true, uniqueness: true, inclusion: { in: GROUP_KEYS }
  # A row's existence is what stops the backfill retrying, so a partial one
  # would sit blank forever.
  validates(*AiService::RECOGNITION_GUIDE_FIELDS, presence: true)

  # The guide shown above a group block on the Learn index, or nil for a block
  # that has none.
  def self.key_for(bucket, group)
    key = group == ConceptGroup::CORE ? bucket : group
    key if GROUP_KEYS.include?(key)
  end

  def self.concepts_for(group_key)
    return ConceptBucket.vocabulary_for(group_key) if ConceptBucket::LANGUAGE_INDEPENDENT.include?(group_key)

    ConceptGroup.concepts(group_key)
  end

  def self.subject_for(group_key)
    NAMED_GROUP_SUBJECTS.fetch(group_key) { AiService::LANGUAGE_CONFIG.fetch(group_key).fetch(:focus) }
  end

  def self.framing_for(group_key)
    FRAMINGS[group_key]
  end
end
