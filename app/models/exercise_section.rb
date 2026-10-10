# Design notes: docs/code-notes/app/models/exercise_section.md
class ExerciseSection
  MAX_SCAFFOLD_LABELS       = 4
  MAX_SCAFFOLD_LABEL_LENGTH = 80

  # Its own fact rather than the slot count: a second fixed kind adds a slot without making a day longer.
  MAX_SECTIONS = 4

  def self.all
    [ CodeReview, DesignComparison, Pattern, Challenge, Architecture, SecurityReview, ParsonsProblem,
      PlanReview, AmbiguityHunt, PseudocodeToCode ]
  end

  def self.keys
    all.map(&:key)
  end

  def self.learning_track_lead
    all.find(&:leads_learning_track?)
  end

  def self.fixed
    all.select(&:fixed?)
  end

  def self.thirds
    [ Architecture, SecurityReview, Challenge, ParsonsProblem ]
  end

  def self.fourths
    [ PlanReview, AmbiguityHunt, PseudocodeToCode ]
  end

  def self.present?(problem_set, key)
    problem_set[key].is_a?(Hash)
  end

  def self.resolved_fourth_key(problem_set)
    resolved_key(problem_set, fourths)
  end

  def self.resolved_key(problem_set, kinds)
    kinds.map(&:key).find { |key| present?(problem_set, key) }
  end

  def self.resolved_keys(problem_set)
    slots.values.filter_map { |kinds| resolved_key(problem_set, kinds) }.first(MAX_SECTIONS)
  end

  def self.fixed_sections_share?(problem_set, concept)
    concept.present? && fixed.all? { |kind| present?(problem_set, kind.key) && problem_set[kind.key]["concept"] == concept }
  end

  def self.slots
    fixed.to_h { |kind| [ kind.key.to_sym, [ kind ] ] }
      .merge(pattern: [ Pattern ], third: thirds, fourth: fourths)
  end

  def self.slot_for(kind)
    slots.find { |_slot, kinds| kinds.include?(kind) }&.first
  end

  def self.all_answer_key_fields
    all.flat_map(&:answer_key_fields).uniq
  end

  def self.rotatable
    slots.values.select { |kinds| kinds.size > 1 }.flatten
  end

  def self.for_plan(third:, fourth:, pattern: :pattern)
    slot_kinds(third: third, fourth: fourth, pattern: pattern).values.compact
  end

  def self.slot_kinds(third:, fourth:, pattern: :pattern)
    chosen = fixed.to_h { |kind| [ kind.key.to_sym, kind.key.to_sym ] }
      .merge(pattern: pattern, third: third, fourth: fourth)

    slots.to_h { |slot, eligible| [ slot, slot_kind(chosen.fetch(slot), eligible) ] }
  end

  def self.slot_kind(rolled, eligible)
    return nil if rolled.nil?

    eligible.find { |kind| kind.key == rolled.to_s } ||
      raise(ArgumentError, "#{rolled.inspect} is not one of: #{eligible.map(&:key).join(', ')}")
  end
  private_class_method :slot_kind

  def self.find(key)
    all.find { |section| section.key == key.to_s }
  end

  def self.for(key)
    find(key) || self
  end

  class << self
    def key
      name.demodulize.underscore
    end

    def third?
      ExerciseSection.thirds.include?(self)
    end

    def fourth?
      ExerciseSection.fourths.include?(self)
    end

    def fixed?
      false
    end

    def vocabulary_key
      :concepts
    end

    def excluded_vocabulary_keys
      []
    end

    def narrow_vocabulary(vocabulary, rung: nil)
      vocabulary
    end

    def answer_key_fields
      []
    end

    def code_fields
      []
    end

    def arrange!(section)
    end

    # Raises AiService::InvalidResponseError for an unusable section; ingest then leaves out only that section.
    def reject_unusable!(section)
    end

    # Indentation is part of the contract: first line unindented, fields at 4, closing brace at 2.
    def schema_fragment(label:)
      raise NotImplementedError, "#{self} must implement .schema_fragment"
    end

    def review_context(section:, answer:, rating:)
      raise NotImplementedError, "#{self} must implement .review_context"
    end

    def answer_lines(answer, rating)
      "#{UserText.labelled('Their answer:', answer)}\n" \
      "Their self-rating: #{rating.presence || '(none given)'}"
    end

    def grading_note(section:, answer:)
      ""
    end

    # Every kind gets the same context and states only its own vocabulary (#81); absorb unread values with `**`.
    def generation_guidance(vocabulary:, label:, mode: nil, artifact: nil, test_framework: nil, source: nil, rung: nil)
      raise NotImplementedError, "#{self} must implement .generation_guidance"
    end

    def improved_code?
      true
    end

    def fixed_rating(section:, answer:)
      nil
    end

    def leads_learning_track?
      false
    end

    def judge_task
      raise NotImplementedError, "#{name} must state its task"
    end

    def discovery?
      false
    end

    def prose_fields
      %w[title scenario question teaching_note]
    end

    def judge_retries
      fixed? ? 2 : 1
    end

    def judge_guidance
      nil
    end

    def rejudge_edits?
      false
    end

    def judge_solve_options
      nil
    end

    def solve_matches_key?(section, solve)
      raise NotImplementedError, "#{self} has judge_solve_options and must compare a solve with its key"
    end

    def translated_before_grading?
      false
    end

    def improved_code_label
      "Improved code"
    end

    def improved_code_prose?
      false
    end

    def body_partial
      "responses/bodies/#{key}"
    end

    def titled_label?
      true
    end

    def answer_partial
      "responses/answers/textarea"
    end

    def answer_class
      "answer"
    end

    def reference_opens_before_answer?
      true
    end

    def diagrammable?
      false
    end

    def default_scaffold
      nil
    end

    def scaffolded?
      default_scaffold.present?
    end

    def scaffold_labels(section_data)
      return [] unless scaffolded?

      normalize_scaffold(section_data.is_a?(Hash) ? section_data["answer_scaffold"] : nil)
        .presence || default_scaffold
    end

    def normalize_scaffold(raw)
      return [] unless raw.is_a?(Array)

      raw.grep(String)
         .filter_map { |label| label.strip.presence&.truncate(MAX_SCAFFOLD_LABEL_LENGTH) }
         .first(MAX_SCAFFOLD_LABELS)
    end

    def scaffold_template(section_data = nil)
      labels = scaffold_labels(section_data)
      return nil if labels.empty?

      labels.join("\n\n\n") + "\n"
    end

    def answered?(value, section_data = nil)
      substantive_answer(value, section_data).length > DailyResponse::ANSWER_MIN_LENGTH
    end

    def answer_for(value, section_data = nil)
      value if answered?(value, section_data)
    end

    def decode_answer(value, exercise: nil, key: nil, section_data: nil)
      value
    end

    def substantive_answer(value, section_data = nil)
      text   = value.to_s
      labels = scaffold_labels(section_data)
      return text.strip if labels.empty?

      text.lines.reject { |line| labels.include?(line.strip) }.join.strip
    end
  end
end
