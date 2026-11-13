# Teaches a process, never an answer, so it shows with no exposure gating (see RecognitionGuidePrompt::SCOPE).
class RecognitionGuide < ApplicationRecord
  FIELDS = %w[questions contrast misfires].freeze

  GROUP_KEYS = (ConceptGroup::NAMED.map(&:first) + ConceptBucket::LANGUAGE_INDEPENDENT).freeze

  # Language-independent buckets state their subject as their LanguagePrompts::ALL focus, so they aren't repeated here.
  NAMED_GROUP_SUBJECTS = {
    "data_modeling"      => "flaws in how data is structured and stored: tables, keys, constraints, indexes, and the migrations that change them.",
    "domain_modeling"    => "whether the model's names match the words the business uses, and which things must change together behind one entry point.",
    "silent_correctness" => "defects that survive every normal check: the code runs, nothing raises, no validator fires, and the output is wrong anyway.",
    "meta_skill"         => "reading code before judging it: what it is for, what it quietly assumes, and whether a problem you can see is the cause or only a symptom.",
    "code_smell"         => "shapes in code that signal a design problem before any bug appears.",
    "oo_design"          => "design principles: rules for how responsibilities and dependencies between classes should run.",
    "module_design"      => "what a module's interface costs every caller, compared with how much the module hides."
  }.freeze

  # Meta-skill concepts are already process concepts, so a generic recognition piece would repeat their references.
  FRAMINGS = {
    "meta_skill" => "These concepts are reasoning skills the app tracks one by one, not kinds of defect. " \
                    "Frame this piece as the one habit they exercise together, reading code carefully before " \
                    "judging it, and show how they fit into a single pass. Leave each concept's detail to its own reference."
  }.freeze

  belongs_to :user, optional: true

  validates :group_key, presence: true, uniqueness: { scope: :user_id }, inclusion: { in: GROUP_KEYS }
  # A row's existence stops the backfill retrying, so a partial one would stay blank forever.
  validates(*FIELDS, presence: true)

  scope :visible_to, ->(user) { where(user_id: user.id) }

  def self.seen_by(user, group_keys)
    visible_to(user).where(group_key: group_keys).index_by(&:group_key)
  end

  def self.written_for?(user, group_key)
    visible_to(user).exists?(group_key: group_key)
  end

  def self.missing_for(user, group_keys)
    return [] if group_keys.empty?

    group_keys - seen_by(user, group_keys).keys
  end

  # Nil for a block with no guide.
  def self.key_for(bucket, group)
    key = group == ConceptGroup::CORE ? bucket : group
    key if GROUP_KEYS.include?(key)
  end

  def self.concepts_for(group_key)
    return ConceptBucket.vocabulary_for(group_key) if ConceptBucket::LANGUAGE_INDEPENDENT.include?(group_key)

    ConceptGroup.concepts(group_key)
  end

  def self.framing_for(group_key)
    FRAMINGS[group_key]
  end
end
