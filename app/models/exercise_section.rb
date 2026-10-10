# Closed: adding a kind means adding a subclass here, not persisting a new string.
class ExerciseSection
  # Bounded because this provider output is rendered straight into the form.
  MAX_SCAFFOLD_LABELS       = 4
  MAX_SCAFFOLD_LABEL_LENGTH = 80

  # Its own fact rather than the slot count: a second fixed kind adds a slot without making a day longer.
  MAX_SECTIONS = 4

  # Enumeration order; anything deriving a Hash or Array from it keeps the order it already had.
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

  # The kinds every day is built around, each in a slot of its own.
  def self.fixed
    all.select(&:fixed?)
  end

  # Precedence order, not enumeration order, for a problem_set holding more than one third key.
  def self.thirds
    [ Architecture, SecurityReview, Challenge, ParsonsProblem ]
  end

  # Precedence order for a problem_set holding more than one fourth key.
  def self.fourths
    [ PlanReview, AmbiguityHunt, PseudocodeToCode ]
  end

  # A provider can emit a key holding null or a bare string beside the real section.
  def self.present?(problem_set, key)
    problem_set[key].is_a?(Hash)
  end

  def self.resolved_fourth_key(problem_set)
    resolved_key(problem_set, fourths)
  end

  # The first of `kinds` the payload holds, by their precedence order, or nil.
  def self.resolved_key(problem_set, kinds)
    kinds.map(&:key).find { |key| present?(problem_set, key) }
  end

  # Capped at MAX_SECTIONS with fixed slots first, so the cut always falls on an optional slot.
  def self.resolved_keys(problem_set)
    slots.values.filter_map { |kinds| resolved_key(problem_set, kinds) }.first(MAX_SECTIONS)
  end

  # False when a fixed section is missing or tagged otherwise, so an ignored placement never reads as delivered.
  def self.fixed_sections_share?(problem_set, concept)
    concept.present? && fixed.all? { |kind| present?(problem_set, kind.key) && problem_set[kind.key]["concept"] == concept }
  end

  # Every slot but a fixed kind's may be nil, meaning the day does not include it.
  def self.slots
    fixed.to_h { |kind| [ kind.key.to_sym, [ kind ] ] }
      .merge(pattern: [ Pattern ], third: thirds, fourth: fourths)
  end

  def self.slot_for(kind)
    slots.find { |_slot, kinds| kinds.include?(kind) }&.first
  end

  # Data the grader reads that nothing before submission may show, log or send to a model.
  def self.all_answer_key_fields
    all.flat_map(&:answer_key_fields).uniq
  end

  # A slot holding one candidate is left out: a weight there could change nothing.
  def self.rotatable
    slots.values.select { |kinds| kinds.size > 1 }.flatten
  end

  # Works from DailyPlan's rolled symbols, before the provider is contacted.
  def self.for_plan(third:, fourth:, pattern: :pattern)
    slot_kinds(third: third, fourth: fourth, pattern: pattern).values.compact
  end

  # Keyed by slot: #for_plan drops omitted slots, so reading it by position names the wrong kind.
  def self.slot_kinds(third:, fourth:, pattern: :pattern)
    chosen = fixed.to_h { |kind| [ kind.key.to_sym, kind.key.to_sym ] }
      .merge(pattern: pattern, third: third, fourth: fourth)

    slots.to_h { |slot, eligible| [ slot, slot_kind(chosen.fetch(slot), eligible) ] }
  end

  # Raises on an ineligible symbol: a silently missing section is worse than a failed generation.
  def self.slot_kind(rolled, eligible)
    return nil if rolled.nil?

    eligible.find { |kind| kind.key == rolled.to_s } ||
      raise(ArgumentError, "#{rolled.inspect} is not one of: #{eligible.map(&:key).join(', ')}")
  end
  private_class_method :slot_kind

  # Never raises: a provider can put arbitrary keys in a jsonb payload.
  def self.find(key)
    all.find { |section| section.key == key.to_s }
  end

  # The base class carries every default, so callers need no `find(k)&.facet || default` fallback.
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

    # AiService owns the constants; this only names which one applies.
    def vocabulary_key
      :concepts
    end

    # Generation-time only: ingest still accepts an excluded concept, since rewriting a real tag destroys history.
    def excluded_vocabulary_keys
      []
    end

    # A nil rung means the caller does not know it; a kind that narrows by level then returns its strictest list.
    def narrow_vocabulary(vocabulary, rung: nil)
      vocabulary
    end

    # See ExerciseSection.all_answer_key_fields.
    def answer_key_fields
      []
    end

    # Parsons blocks are left out on purpose: each block's indentation is part of the arrangement.
    def code_fields
      []
    end

    # Applied after .reject_unusable! accepts the section. Most kinds have nothing to arrange.
    def arrange!(section)
    end

    # Raises AiService::InvalidResponseError for an unusable section; ingest then leaves out only that section.
    def reject_unusable!(section)
    end

    # Indentation is part of the contract: first line unindented, fields at 4, closing brace at 2.
    def schema_fragment(label:)
      raise NotImplementedError, "#{self} must implement .schema_fragment"
    end

    # Abstract: a kind returning nothing would produce a review missing its context with no signal.
    def review_context(section:, answer:, rating:)
      raise NotImplementedError, "#{self} must implement .review_context"
    end

    def answer_lines(answer, rating)
      "#{UserText.labelled('Their answer:', answer)}\n" \
      "Their self-rating: #{rating.presence || '(none given)'}"
    end

    # The kind's main point and essential pieces; never restate AiService::RATING_RUBRIC here.
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

    # nil when the grader chooses the rating under AiService::RATING_RUBRIC.
    def fixed_rating(section:, answer:)
      nil
    end

    def leads_learning_track?
      false
    end

    # ── Read only by the judge (AiService#judge_section), never by the draft prompt or grading ──

    # Abstract: a new kind with no stated task must fail loudly rather than ship unjudged.
    def judge_task
      raise NotImplementedError, "#{name} must state its task"
    end

    def discovery?
      false
    end

    # The fields the judge may rewrite. Everything else is the artifact.
    def prose_fields
      %w[title scenario question teaching_note]
    end

    # A fixed kind gets one more retry, since every day is built around it.
    def judge_retries
      fixed? ? 2 : 1
    end

    def judge_guidance
      nil
    end

    # True where the editable prose decides the answer, so a rewrite could change which answer is right.
    def rejudge_edits?
      false
    end

    # nil when the judge does not solve this kind. A solve is an answer candidate, so it stays out of every log.
    def judge_solve_options
      nil
    end

    # Only called for a kind with .judge_solve_options.
    def solve_matches_key?(section, solve)
      raise NotImplementedError, "#{self} has judge_solve_options and must compare a solve with its key"
    end

    # A declared per-kind fact rather than a name comparison in the review path.
    def translated_before_grading?
      false
    end

    # Defaults to corrected source; a kind whose improvement is prose overrides these.
    def improved_code_label
      "Improved code"
    end

    def improved_code_prose?
      false
    end

    # ── How this kind renders: user-facing strings live in config/locales/en.yml under sections.<key> ──

    def body_partial
      "responses/bodies/#{key}"
    end

    # False for kinds whose problem_set carries no title of its own.
    def titled_label?
      true
    end

    def answer_partial
      "responses/answers/textarea"
    end

    def answer_class
      "answer"
    end

    # False for a kind whose reference would name what the grade asks the engineer to supply.
    def reference_opens_before_answer?
      true
    end

    # False by default: a diagram is safe pre-answer only where it restates what is already on screen.
    def diagrammable?
      false
    end

    # nil for kinds that are never pre-filled and never have labels stripped.
    def default_scaffold
      nil
    end

    def scaffolded?
      default_scaffold.present?
    end

    # DEFAULT_SCAFFOLD covers rows and providers without answer_scaffold.
    def scaffold_labels(section_data)
      return [] unless scaffolded?

      normalize_scaffold(section_data.is_a?(Hash) ? section_data["answer_scaffold"] : nil)
        .presence || default_scaffold
    end

    # Model-generated text rendered into a textarea and a data attribute, so it is bounded and sanitized.
    def normalize_scaffold(raw)
      return [] unless raw.is_a?(Array)

      raw.grep(String)
         .filter_map { |label| label.strip.presence&.truncate(MAX_SCAFFOLD_LABEL_LENGTH) }
         .first(MAX_SCAFFOLD_LABELS)
    end

    # The blank lines make the scaffold read as a form to fill.
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

    # nil drops the section from the payload rather than storing something unreadable over the draft.
    def decode_answer(value, exercise: nil, key: nil, section_data: nil)
      value
    end

    # Matches whole stripped lines, so an edited label becomes the user's own text and counts.
    def substantive_answer(value, section_data = nil)
      text   = value.to_s
      labels = scaffold_labels(section_data)
      return text.strip if labels.empty?

      text.lines.reject { |line| labels.include?(line.strip) }.join.strip
    end
  end
end
