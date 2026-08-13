# The kinds of section a daily problem set can hold. Each kind is a named class
# rather than a bare string so the facets that vary per kind — which vocabulary
# its concept is validated against, whether its review can carry improved_code,
# whether it can occupy the rolled third slot — live in one place instead of
# being re-derived by a conditional at each call site.
#
# Deliberately closed, like the concept vocabularies these select: adding a kind
# means adding a subclass here, not persisting a new string.
class ExerciseSection
  # Bounds on the model-generated `answer_scaffold`. Enough labels to decompose
  # an answer, short enough to read as a label rather than a paragraph — and,
  # more to the point, bounded at all, since this is provider output rendered
  # straight into the form.
  MAX_SCAFFOLD_LABELS       = 4
  MAX_SCAFFOLD_LABEL_LENGTH = 80

  # Enumeration order, matching the order these keys have always been listed in
  # (strong params, concept tagging, scenario collection) so anything deriving a
  # Hash or Array from it keeps the ordering it already had.
  def self.all
    [ CodeReview, Pattern, Challenge, Architecture, SecurityReview, ParsonsProblem,
      PlanReview, AmbiguityHunt ]
  end

  def self.keys
    all.map(&:key)
  end

  # Precedence order, NOT enumeration order: a problem_set holding more than one
  # third key (a provider returning both) resolves the way it always has —
  # architecture first, then security_review, then challenge, then
  # parsons_problem.
  def self.thirds
    [ Architecture, SecurityReview, Challenge, ParsonsProblem ]
  end

  # Precedence order for the fourth slot, mirroring .thirds: if a provider
  # somehow returned both fourth-shaped keys, plan_review wins.
  def self.fourths
    [ PlanReview, AmbiguityHunt ]
  end

  # Which fourth-slot key a raw problem_set resolves to, by .fourths
  # precedence — nil when it holds none. Lives here rather than on
  # DailyExercise because the generation-time normalizers have to resolve the
  # same slot on a payload that isn't a row yet, and two copies of a
  # precedence rule is one copy too many.
  def self.resolved_fourth_key(problem_set)
    fourths.map(&:key).find { |key| problem_set[key].is_a?(Hash) }
  end

  # The day's four kinds in slot order, for a set that hasn't been generated
  # yet. Same reason .resolved_fourth_key lives here: the generation path has
  # to resolve slots before a DailyExercise row exists, working from DailyPlan's
  # rolled symbols rather than a persisted payload.
  # DailyExercise#active_section_keys answers the same question after the fact.
  def self.for_plan(third:, fourth:)
    [ CodeReview, Pattern, slot_kind(third, thirds), slot_kind(fourth, fourths) ]
  end

  # Raises rather than returning nil: a kind that isn't eligible for the slot
  # it was rolled into is a bug in the plan, and a set silently missing a
  # section is worse than a failed generation the user can retry.
  def self.slot_kind(rolled, eligible)
    eligible.find { |kind| kind.key == rolled.to_s } ||
      raise(ArgumentError, "#{rolled.inspect} is not one of: #{eligible.map(&:key).join(', ')}")
  end
  private_class_method :slot_kind

  # nil for anything outside the closed set. Callers decide what an unrecognized
  # section means; a provider can put arbitrary keys in a jsonb payload, so this
  # never raises.
  def self.find(key)
    all.find { |section| section.key == key.to_s }
  end

  # #find, for callers that only want to read a facet and have no interesting
  # answer for an unrecognized key. The base class carries every default, so
  # this keeps the fallback in one place instead of making each caller restate
  # it (`ExerciseSection.find(k)&.improved_code_label || "Improved code"`).
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

    # Names which vocabulary this kind's concept is validated against. AiService
    # owns the constants themselves — this only says which one applies, so the
    # vocabularies stay closed Ruby constants in one place.
    def vocabulary_key
      :concepts
    end

    # This kind's entry in the generation schema — the JSON object the provider
    # is told to return for it, under this kind's own key. `label` names the
    # day's language for the code-bearing fields; AiService still owns
    # LANGUAGE_CONFIG, so a kind knows where the language name goes, never how
    # it was resolved.
    #
    # Formatted to sit at one level of nesting inside the schema object: first
    # line unindented, fields at 4, closing brace at 2. The assembler
    # interpolates it directly (see AiService#exercise_schema_for), so this
    # indentation is part of the contract, not incidental.
    def schema_fragment(label:)
      raise NotImplementedError, "#{self} must implement .schema_fragment"
    end

    # The generation prompt's instruction block for this kind — how to write
    # it, and which vocabulary its concept comes from. Every kind states its
    # own vocabulary and none speaks for another, which is what keeps the
    # instruction a reader sees for one section independent of what rolled
    # into another (see issue #81, fixed by that rule).
    #
    # `vocabulary` is this kind's own, resolved by the caller from
    # .vocabulary_key. `mode` is the rolled content mode, for kinds that have
    # one — only code_review does today.
    def generation_guidance(vocabulary:, label:, mode: nil)
      raise NotImplementedError, "#{self} must implement .generation_guidance"
    end

    # Whether a review of this kind can carry corrected code.
    def improved_code?
      true
    end

    # What the review's improved_code actually IS for this kind, and whether it
    # is prose rather than source. Both default to corrected source, which is
    # what every code-bearing kind carries — a kind whose "improvement" is
    # written English says so here, so the review view and the review email
    # don't each have to special-case it.
    def improved_code_label
      "Improved code"
    end

    def improved_code_prose?
      false
    end

    # ── How this kind renders ────────────────────────────────────────────────
    # Structural facts only. The user-facing strings (section name, textarea
    # placeholder) live in config/locales/en.yml under `sections.<key>`, which
    # is where this app already keeps user-facing copy — unlike the prompt
    # text above, which is provider-facing and has no other home.

    # The partial rendering the part of this section no shared wrapper can:
    # the snippet, the plan excerpt, the option list, the block ladder.
    def body_partial
      "responses/bodies/#{key}"
    end

    # Whether the section label appends the day's title ("4 — Plan Review:
    # Backfill the ledger"). False for the two kinds whose problem_set carries
    # no title of its own.
    def titled_label?
      true
    end

    # The answer input this kind offers while unsubmitted. Every kind but one
    # takes a plain textarea; parsons_problem's answer is an ordering, so it
    # brings its own control.
    def answer_partial
      "responses/answers/textarea"
    end

    # Extra class on that textarea — challenge is answered in code, so it gets
    # the monospace treatment.
    def answer_class
      "answer"
    end

    # Whether this kind's problem_set may carry a Mermaid `diagram` of the
    # structure its scenario describes. False by default: a diagram is only
    # safe pre-answer where it restates something already on screen, which is
    # not true of a kind whose whole task is finding what is hidden in a
    # snippet (security_review) or arranging the structure itself
    # (parsons_problem).
    def diagrammable?
      false
    end

    # Whether this kind's answer is scaffolded, and with what labels when the
    # day's problem carries none. nil for kinds that take a single unstructured
    # answer — those are never pre-filled and never have labels stripped.
    def default_scaffold
      nil
    end

    def scaffolded?
      default_scaffold.present?
    end

    # The labels actually in play for one day's problem. The generator tailors
    # `answer_scaffold` to the question it just wrote; DEFAULT_SCAFFOLD covers
    # rows generated before that field existed and any provider that omits it,
    # so a scaffolded kind always has labels and an unscaffolded one never does.
    def scaffold_labels(section_data)
      return [] unless scaffolded?

      normalize_scaffold(section_data.is_a?(Hash) ? section_data["answer_scaffold"] : nil)
        .presence || default_scaffold
    end

    # Bounded and sanitized because this is model-generated text rendered into a
    # textarea and a data attribute: labels are stripped, blanks and non-strings
    # dropped, each truncated, and the list capped. Anything left unusable falls
    # back to DEFAULT_SCAFFOLD via scaffold_labels.
    def normalize_scaffold(raw)
      return [] unless raw.is_a?(Array)

      raw.grep(String)
         .filter_map { |label| label.strip.presence&.truncate(MAX_SCAFFOLD_LABEL_LENGTH) }
         .first(MAX_SCAFFOLD_LABELS)
    end

    # Starting value for a fresh textarea: each label followed by room to write
    # under it. The blank lines are what make the scaffold feel like a form to
    # fill rather than a paragraph to edit.
    def scaffold_template(section_data = nil)
      labels = scaffold_labels(section_data)
      return nil if labels.empty?

      labels.join("\n\n\n") + "\n"
    end

    # The answer with this day's scaffold labels removed, so "how much did the
    # user actually write" never counts the scaffolding we gave them. Matching
    # whole stripped lines (not substrings) is what makes partial edits degrade
    # gracefully: an untouched label is removed, an edited one becomes the
    # user's own text and counts.
    def substantive_answer(value, section_data = nil)
      text   = value.to_s
      labels = scaffold_labels(section_data)
      return text.strip if labels.empty?

      text.lines.reject { |line| labels.include?(line.strip) }.join.strip
    end
  end
end
