# Turns a parsed provider problem set into one that is safe to persist:
# concepts held to their closed vocabulary, scaffolds and diagrams bounded,
# parsons blocks scrambled for display, and the ambiguity hunt's answer key
# validated. This is the generation boundary — the one place provider output
# is checked before anything downstream is allowed to assume it is clean.
#
# Takes an already-parsed Hash rather than raw text: AiService#parse_json_object
# is shared with the review and concept-reference paths, so parsing belongs
# there, not in a problem-set-specific module.
#
# WRITES NOTHING. Off-vocabulary concepts come back in the Result as
# suggestions for the caller to record. That is what makes "a rejected set must
# not leave a vocabulary suggestion behind" a structural guarantee rather than
# a consequence of the order these steps run in — when this raises, nothing has
# been written, because this never writes. It also means the whole module is
# pure, so its tests need no database.
class ProblemSetIngest
  # The one field in a problem set that is answer-key data rather than exercise
  # content. Two places know it by name: the validation below that guarantees
  # it is usable, and AiService#without_answer_key, the diagnostics log that
  # must never carry it.
  ANSWER_KEY_FIELD = "planted_ambiguities".freeze

  # Upper bound on a section's Mermaid `diagram`. The prompt asks for at most
  # 8 nodes with short labels, which lands well under half this — so the bound
  # rejects runaway output without rejecting anything actually asked for.
  MAX_DIAGRAM_LENGTH = 1_000

  # An off-vocabulary concept the provider invented. `bucket` is the vocabulary
  # bucket it would have belonged to, which is what SuggestedConcept records
  # under.
  Suggestion = Data.define(:bucket, :name)

  Result = Data.define(:problem_set, :suggested_concepts)

  # Raises AiService::InvalidResponseError when the set cannot be used at all.
  def self.call(problem_set, language:, expected_keys:)
    new(problem_set, language: language, expected_keys: expected_keys).call
  end

  # ── Two lookups, deliberately not one ────────────────────────────────────
  # What a section's concept is VALIDATED against, and what generation may
  # OFFER it, are different questions, and the answers diverge on purpose.
  # They were briefly one method distinguished by whether a `mode:` was
  # passed, which only worked while code_review was the sole kind that
  # narrowed — parsons_problem narrows without a mode, and a nil-check cannot
  # tell "generating a parsons problem" from "validating one".

  # The closed vocabulary a section's concept is validated against, at ingest.
  # Never narrowed: a concept the provider actually tagged is history, and
  # rewriting it to "other" over a preference about what to ask for would
  # destroy the record rather than correct it.
  #
  # An unrecognized section key — a provider can invent one — falls back to the
  # language's full vocabulary, as it always has.
  def self.vocabulary_for(section_key, language)
    case ExerciseSection.find(section_key)&.vocabulary_key
    when :architecture      then AiService::ARCHITECTURE_CONCEPTS
    when :security_concepts then language_config(language)[:security_concepts]
    when :plan_review       then AiService::PLAN_REVIEW_CONCEPTS
    when :ambiguity_hunt    then AiService::AMBIGUITY_HUNT_CONCEPTS
    else                         language_config(language)[:concepts]
    end
  end

  # What the generation prompt may offer a section, which is the validation
  # vocabulary minus two narrowings:
  #
  #   - code_review's content mode, which swaps the list wholesale
  #   - the kind's own excluded group, for concepts whose shape its format
  #     cannot express (see ExerciseSection.excluded_vocabulary_keys)
  #
  # The narrowing is always a subset of what validation accepts, so no caller
  # can name a list ingest would then reject a concept from. Two callers rely
  # on that: AiService#generation_guidance_for, for what the prompt offers a
  # section, and AiService#can_host?, for which sections a due retention check
  # may be annotated toward. Anything reading this must be asking what may be
  # *requested* — never what is valid on arrival, which is .vocabulary_for.
  def self.selectable_vocabulary_for(section_key, language, mode: nil)
    vocabulary =
      if mode && section_key == ExerciseSection::CodeReview.key
        code_review_vocabulary(language, mode)
      else
        vocabulary_for(section_key, language)
      end

    excluded = excluded_concepts_for(section_key)
    excluded.empty? ? vocabulary : vocabulary - excluded
  end

  # Only code_review's mode narrows this way. Subtracting the data-modeling
  # concepts leaves the other two modes drawing the day's full language
  # vocabulary minus that group.
  def self.code_review_vocabulary(language, mode)
    full = language_config(language)[:concepts]
    mode == :schema_review ? AiService::DATA_MODELING_CONCEPTS : full - AiService::DATA_MODELING_CONCEPTS
  end
  private_class_method :code_review_vocabulary

  # The kind names its excluded groups; the constants live here, matching how
  # vocabulary_key resolves. ExerciseSection.for carries the empty default, so
  # a section key the provider invented excludes nothing rather than raising.
  def self.excluded_concepts_for(section_key)
    ExerciseSection.for(section_key).excluded_vocabulary_keys.flat_map do |key|
      case key
      when :data_modeling then AiService::DATA_MODELING_CONCEPTS
      when :meta_skill    then AiService::META_SKILL_CONCEPTS
      when :code_smell    then AiService::CODE_SMELL_CONCEPTS
      else                     []
      end
    end
  end
  private_class_method :excluded_concepts_for

  # The vocabularies still live on AiService, which is the wrong home for them
  # now that this module is their other reader — they are domain data, not
  # provider data. Moving them (to a ConceptVocabulary of their own) is a
  # separate change; until then this reads them where they are rather than
  # taking a copy that could drift.
  def self.language_config(language)
    AiService::LANGUAGE_CONFIG.fetch(language) do
      raise AiService::Error, "Unsupported generation language: #{language.inspect}"
    end
  end
  private_class_method :language_config

  def initialize(problem_set, language:, expected_keys:)
    @problem_set        = problem_set
    @language           = language
    @expected_keys      = expected_keys
    @suggested_concepts = []
  end

  # Answer-key validation runs first because it is the only step that can
  # reject the set, and there is no reason to bound scaffolds on a payload
  # about to be thrown away. It is no longer load-bearing for correctness:
  # nothing here writes, so no ordering can leave a stray row behind.
  def call
    reject_missing_sections!
    reject_unusable_answer_key!
    normalize_concepts!
    normalize_answer_scaffolds!
    normalize_diagrams!
    shuffle_parsons_blocks!

    Result.new(problem_set: @problem_set, suggested_concepts: @suggested_concepts)
  end

  private

  # A silently short set would make sections_total under-report, which feeds
  # recent_performance, which sizes tomorrow's set — the day's own provider
  # glitch nudging future days shorter. Extra sections are fine: FakeService
  # returns all eight, and only the resolved ones are ever rendered.
  def reject_missing_sections!
    missing = @expected_keys.reject { |key| ExerciseSection.present?(@problem_set, key) }
    return if missing.empty?

    raise AiService::InvalidResponseError,
          "Provider omitted intended section(s): #{missing.join(', ')}"
  end

  # Unlike every other step, this one rejects rather than repairs. The planted
  # list is the ambiguity hunt's entire grading ground truth — the review
  # prompt grades coverage against it and nothing else — so an empty or
  # unusable list doesn't degrade the section, it silently turns coverage
  # grading back into the freehand judgement the kind exists to replace, and
  # there is no fallback to fall back to. InvalidResponseError is already a
  # surfaced, retryable generation failure
  # (GenerateDailyExercisesJob#persist_failure), so failing costs the user a
  # retry rather than a day of ungrounded grading.
  #
  # A WRONG COUNT IS NOT A FAILURE, though. The prompt asks for exactly
  # ExerciseSection::AmbiguityHunt::PLANTED_COUNT, but nothing downstream reads
  # that number, so a list of 3 or 5 grades exactly as well — and rejecting it
  # would throw away the day's other three sections over the likeliest
  # deviation an LLM makes on a counted list. Only the empty case is fatal;
  # the long case is truncated.
  #
  # Scoped to the RESOLVED fourth section, not to the mere presence of the key:
  # a provider that returns both fourth shapes leaves an ambiguity_hunt nothing
  # downstream will ever render or grade (plan_review wins the slot), and
  # discarding a good day over an answer key no one reads would be a strictly
  # worse outcome than ignoring it.
  def reject_unusable_answer_key!
    return unless ExerciseSection.resolved_fourth_key(@problem_set) == "ambiguity_hunt"

    section = @problem_set["ambiguity_hunt"]

    # Shape is held to the schema even though count isn't: a bare string here
    # is not four ambiguities, it's a provider that ignored the field's type,
    # and Array() would quietly launder it into a single-entry answer key.
    raw     = section[ANSWER_KEY_FIELD]
    planted = raw.is_a?(Array) ? raw.grep(String).filter_map { |entry| entry.strip.presence } : []
    if planted.empty?
      raise AiService::InvalidResponseError,
            "Ambiguity hunt returned no usable #{ANSWER_KEY_FIELD} to grade coverage against"
    end

    section[ANSWER_KEY_FIELD] = planted.first(ExerciseSection::AmbiguityHunt::MAX_PLANTED)
  end

  # A provider occasionally invents tags; keep the vocabulary closed so
  # aggregation over concept history stays clean. Off-list concepts are still
  # collected as a background signal for future vocabulary growth — that never
  # changes what is persisted to the response itself, which still gets "other".
  def normalize_concepts!
    @problem_set.each do |section_key, section|
      next unless section.is_a?(Hash) && section.key?("concept")

      original = section["concept"]
      next if self.class.vocabulary_for(section_key, @language).include?(original)

      section["concept"] = "other"
      @suggested_concepts << Suggestion.new(bucket: ConceptBucket.for(section_key, @language), name: original)
    end
  end

  # Bounds and sanitizes the model-generated answer_scaffold before it is
  # persisted, so what reaches the form is always a short list of short labels.
  # An unusable or missing scaffold is dropped entirely rather than repaired —
  # ExerciseSection.scaffold_labels then falls back to the kind's default, which
  # is the same path every pre-scaffold row already takes.
  def normalize_answer_scaffolds!
    @problem_set.each do |section_key, section_data|
      kind = ExerciseSection.find(section_key)
      next unless section_data.is_a?(Hash)

      unless kind&.scaffolded?
        section_data.delete("answer_scaffold")
        next
      end

      labels = kind.normalize_scaffold(section_data["answer_scaffold"])
      labels.any? ? section_data["answer_scaffold"] = labels : section_data.delete("answer_scaffold")
    end
  end

  # Mermaid source is provider output rendered straight into an HTML data
  # attribute, so it is bounded here rather than trusted downstream. Anything
  # unusable is deleted, not repaired: the reader then takes the same "no
  # diagram" path every pre-diagram row already takes.
  #
  # Only the top-level key — architecture's diagram lives at reference.diagram,
  # predates this field, and is not touched.
  def normalize_diagrams!
    @problem_set.each do |section_key, section_data|
      next unless section_data.is_a?(Hash)

      diagram = section_data["diagram"]
      usable  = ExerciseSection.find(section_key)&.diagrammable? &&
                diagram.is_a?(String) &&
                diagram.strip.length.between?(1, MAX_DIAGRAM_LENGTH)

      usable ? section_data["diagram"] = diagram.strip : section_data.delete("diagram")
    end
  end

  # The provider returns "blocks" already in correct order, so the scramble is
  # rolled once here and persisted — refreshes and the history view then show
  # the same arrangement. Never the identity permutation, which would ship an
  # already-solved problem.
  def shuffle_parsons_blocks!
    parsons = @problem_set["parsons_problem"]
    return unless parsons.is_a?(Hash) && parsons["blocks"].is_a?(Array)

    identity = (0...parsons["blocks"].size).to_a
    order    = identity.shuffle
    order    = identity.shuffle while order == identity && identity.size > 1
    parsons["display_order"] = order
  end
end
