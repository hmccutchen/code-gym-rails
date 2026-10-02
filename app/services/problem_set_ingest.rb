# Turns a parsed provider problem set into one that is safe to persist:
# concepts held to their closed vocabulary, scaffolds and diagrams bounded,
# parsons blocks scrambled for display, and each resolved section held to its
# kind's own check and arranged by it (ExerciseSection.reject_unusable!,
# .arrange!). This is the generation
# boundary — the one place provider output is checked before anything
# downstream is allowed to assume it is clean.
#
# Takes an already-parsed Hash rather than raw text: AiService#parse_json_object
# is shared with the review and concept-reference paths, so parsing belongs
# there, not in a problem-set-specific module.
#
# WRITES NOTHING TO THE DATABASE. Off-vocabulary concepts come back in the
# Result as suggestions for the caller to record. That is what makes "a
# rejected set must not leave a vocabulary suggestion behind" a structural
# guarantee rather than a consequence of the order these steps run in — when
# this raises, nothing has been persisted, because this never persists. Its
# tests need no database for the same reason. The module is not side-effect
# free, though: warn_unrequested_sections! logs.
class ProblemSetIngest
  # Facts about a section that the server knows and the provider does not: the
  # rung asked for, whether the prompt was told to ease it, which real excerpt
  # it was grounded in, and, on older rows, whether the judge rejected its
  # last retry and it shipped anyway. A provider copy of any of them is
  # stripped from every section on every call, so none can be forged.
  # `anchored` is no longer written, since every kind is now dropped after its
  # last rejected retry; it stays listed so a provider still cannot forge it.
  #
  # They describe how the section was made, not what it asks, so nothing that
  # serializes a section to a model may include them — AiService#judge_section
  # reads this list for exactly that. The review prompt states `pitched_at` as
  # a named line instead, because the rubric rates against that level. `current_schema` is server-owned too and
  # deliberately absent: it is the table the engineer is shown, and the judge
  # has to read it to tell whether the question is answerable.
  SERVER_STAMPS = %w[pitched_at eased source anchored].freeze

  # Upper bound on a section's Mermaid `diagram`. The prompt asks for at most
  # 8 nodes with short labels, which lands well under half this — so the bound
  # rejects runaway output without rejecting anything actually asked for.
  MAX_DIAGRAM_LENGTH = 1_000

  # An off-vocabulary concept the provider invented. `bucket` is the vocabulary
  # bucket it would have belonged to, which is what SuggestedConcept records
  # under.
  Suggestion = Data.define(:bucket, :name)

  # A resolved section its kind's boundary check refused. `concept` is the
  # tag it carried when that tag is in the section's vocabulary, else nil,
  # so a retry is only ever asked for a concept the plan could have placed.
  # `reason` is the check's own message, which never quotes section text.
  Unusable = Data.define(:key, :concept, :reason)

  Result = Data.define(:problem_set, :suggested_concepts, :unusable_sections)

  # Raises AiService::InvalidResponseError when the set cannot be used at all.
  # `code_review_source` is the RealSource excerpt today's code_review was
  # grounded in, or nil for a toy day. `pitched_at` maps each section key to
  # the rung the prompt pitched it at, and `eased_for` to the concepts the
  # prompt was told to ease there; both are server facts stamped into the
  # sections, and a caller that passes neither gets no stamps. `fixed_concepts`
  # maps a section key to the concept a single-section retry demanded — the
  # day's plan already placed that concept there, so a returned section tagging
  # anything else is not a repaired section, it's a wrong one.
  def self.call(problem_set, language:, expected_keys:, code_review_source: nil, pitched_at: nil, eased_for: {}, fixed_concepts: {})
    new(problem_set, language: language, expected_keys: expected_keys, code_review_source: code_review_source,
        pitched_at: pitched_at, eased_for: eased_for, fixed_concepts: fixed_concepts).call
  end

  # The judged path resolves its final set from an already-ingested draft, so
  # it may only drop unexpected top-level keys — never normalize, scramble, or
  # mutate that draft in place. A deep dup keeps the judged set independent of
  # the draft the logs still read.
  def self.prune_to_expected_keys(problem_set, expected_keys:)
    problem_set.deep_dup.slice(*expected_keys)
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
    when :pseudocode_to_code then AiService::PSEUDOCODE_TO_CODE_CONCEPTS
    else                         language_config(language)[:concepts]
    end
  end

  # What the generation prompt may offer a section, which is the validation
  # vocabulary minus three narrowings:
  #
  #   - code_review's content mode, which swaps the list wholesale
  #   - the kind's own excluded group, for concepts whose shape its format
  #     cannot express (see ExerciseSection.excluded_vocabulary_keys)
  #   - the kind's own last say, which may depend on the rung
  #     (see ExerciseSection.narrow_vocabulary)
  #
  # The narrowing is always a subset of what validation accepts, so no caller
  # can name a list ingest would then reject a concept from. Two callers rely
  # on that: AiService#generation_guidance_for, for what the prompt offers a
  # section, and AiService#can_host?, for which sections a due retention check
  # may be annotated toward. Anything reading this must be asking what may be
  # *requested* — never what is valid on arrival, which is .vocabulary_for.
  def self.selectable_vocabulary_for(section_key, language, mode: nil, rung: nil)
    vocabulary =
      if mode && section_key == ExerciseSection::CodeReview.key
        code_review_vocabulary(language, mode)
      else
        vocabulary_for(section_key, language)
      end

    excluded = excluded_concepts_for(section_key)
    remaining = excluded.empty? ? vocabulary : vocabulary - excluded
    ExerciseSection.for(section_key).narrow_vocabulary(remaining, rung: rung) & remaining
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
      when :domain_modeling then AiService::DOMAIN_MODELING_CONCEPTS
      when :meta_skill    then AiService::META_SKILL_CONCEPTS
      when :code_smell    then AiService::CODE_SMELL_CONCEPTS
      when :oo_design     then AiService::OO_DESIGN_CONCEPTS
      when :module_design then AiService::MODULE_DESIGN_CONCEPTS
      when :silent_correctness then AiService::SILENT_CORRECTNESS_CONCEPTS
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

  def initialize(problem_set, language:, expected_keys:, code_review_source: nil, pitched_at: nil, eased_for: {}, fixed_concepts: {})
    @problem_set        = problem_set
    @language           = language
    @expected_keys      = expected_keys
    @code_review_source = code_review_source
    @pitched_at         = pitched_at
    @eased_for          = eased_for
    @fixed_concepts     = fixed_concepts
    @suggested_concepts = []
    @unusable_sections  = []
  end

  # Rejection runs before the normalizers: there is no reason to bound
  # scaffolds or roll a scramble on a payload about to be thrown away. Neither
  # step is load-bearing for correctness — nothing here writes, so no ordering
  # can leave a stray row behind.
  def call
    reject_missing_sections!
    warn_unrequested_sections!
    prune_retry_extras!
    prune_unplanned_slots!
    reject_unusable_sections!
    enforce_fixed_concepts!
    normalize_concepts!
    normalize_answer_scaffolds!
    normalize_diagrams!
    shuffle_parsons_blocks!
    arrange_sections!
    strip_current_schemas!
    strip_server_stamps!
    ground_code_review!
    stamp_pitched_rungs!

    Result.new(problem_set: @problem_set, suggested_concepts: @suggested_concepts, unusable_sections: @unusable_sections)
  end

  private

  # A silently short set would make sections_total under-report, which feeds
  # recent_performance, which sizes tomorrow's set — the day's own provider
  # glitch nudging future days shorter. Extra sections are fine: FakeService
  # returns every kind, and only the resolved ones are ever rendered.
  def reject_missing_sections!
    missing = @expected_keys.reject { |key| ExerciseSection.present?(@problem_set, key) }
    return if missing.empty?

    raise AiService::InvalidResponseError,
          "Provider omitted intended section(s): #{missing.join(', ')}"
  end

  # The other half of the rule above: extras are accepted, but not invisibly.
  # DailyPlan sizes the day and names its sections, yet active_section_keys
  # derives from what is *present*, so an unrequested section the provider
  # threw in is rendered — a day sized at 2 can show 3, defeating the sizing
  # decision with no trace anywhere that it happened. Rejecting would discard
  # usable days over a harmless provider quirk, so this warns instead.
  #
  # Serialized as JSON, not joined: these are provider-controlled hash keys, so
  # a newline in one would otherwise forge a second log line.
  def warn_unrequested_sections!
    unrequested = @problem_set.keys - @expected_keys
    return if unrequested.empty?

    Rails.logger.warn(
      "[unrequested_sections] provider returned section(s) the day did not intend: " \
      "#{unrequested.to_json} (intended: #{@expected_keys.to_json})"
    )
  end

  # A single-section retry asked for exactly one key, so anything else the
  # provider returned is not part of the repaired section this path may keep.
  def prune_retry_extras!
    return if @fixed_concepts.empty?

    @problem_set = self.class.prune_to_expected_keys(@problem_set, expected_keys: @expected_keys)
  end

  # There are more slots than a day holds, so a payload with a shape in every
  # slot resolves past ExerciseSection::MAX_SECTIONS, and the cap in
  # ExerciseSection.resolved_keys would then cut whichever slot comes last,
  # requested or not. Dropping the slots the plan left empty first means the
  # cap only ever trims what nobody asked for. Below the cap an extra section
  # is kept, as warn_unrequested_sections! describes.
  def prune_unplanned_slots!
    return if resolved_slot_count <= ExerciseSection::MAX_SECTIONS

    ExerciseSection.slots.each_value do |kinds|
      keys = kinds.map(&:key)
      @problem_set = @problem_set.except(*keys) if (keys & @expected_keys).empty?
    end
  end

  def resolved_slot_count
    ExerciseSection.slots.values.count { |kinds| ExerciseSection.resolved_key(@problem_set, kinds) }
  end

  # Only the sections the set resolves to: a provider that returns two fourth
  # shapes leaves one that nothing downstream will render or grade, and
  # discarding a good day over a section no one reads would be a strictly
  # worse outcome than ignoring it.
  #
  # A refused section costs only itself: its whole slot leaves the set, so a
  # lower-precedence shape in the same slot cannot take its place unchecked,
  # and the refusal is reported on the Result for the caller to retry or
  # record as dropped. The set is refused only when nothing usable remains.
  # A refused section is removed alone. The next shape in its slot, if the
  # payload holds one, then resolves and is checked in turn rather than taking
  # the slot unchecked.
  def reject_unusable_sections!
    pending = ExerciseSection.resolved_keys(@problem_set)
    while (key = pending.shift)
      successor = reject_if_unusable(key)
      pending << successor if successor
    end
    return if ExerciseSection.resolved_keys(@problem_set).any?

    raise AiService::InvalidResponseError, "No usable section left: #{@unusable_sections.map(&:reason).join('; ')}"
  end

  def reject_if_unusable(key)
    ExerciseSection.for(key).reject_unusable!(@problem_set[key])
    nil
  rescue AiService::InvalidResponseError => e
    @unusable_sections << Unusable.new(key: key, concept: usable_concept(key), reason: e.message)
    @problem_set = @problem_set.except(key)
    ExerciseSection.resolved_key(@problem_set, slot_kinds_for(key))
  end

  def usable_concept(key)
    concept = @problem_set.dig(key, "concept")
    concept if self.class.vocabulary_for(key, @language).include?(concept)
  end

  def slot_kinds_for(key)
    ExerciseSection.slots.values.find { |kinds| kinds.map(&:key).include?(key) }
  end

  # A single-section retry names the concept the day's plan already placed at
  # this key — the rejected section's replacement is not free to retag it.
  # Runs before normalize_concepts!, which would otherwise silently pass a
  # mismatched concept through (or launder it to "other") rather than let the
  # caller know the retry didn't do what it was asked.
  def enforce_fixed_concepts!
    @fixed_concepts.each do |key, concept|
      actual = @problem_set.dig(key, "concept")
      next if actual == concept

      raise AiService::InvalidResponseError,
            "Retry for #{key} returned concept #{actual.inspect}, not #{concept.inspect}"
    end
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

  # The page, the grader, the duck and the difficulty assessment all read
  # `current_schema` as the real table, and the last two read it from
  # whichever section they are handed. So no section keeps a provider's
  # version; ground_code_review! stamps the server's afterward.
  def strip_current_schemas!
    @problem_set.each_value do |section_data|
      section_data.delete("current_schema") if section_data.is_a?(Hash)
    end
  end

  # On a grounded day the scenario is a fact the server knows — which file,
  # which method, and that the copy is altered — not creative output, so it is
  # stamped here regardless of what the provider wrote. The prompt asks for the
  # same string; this is what guarantees it, since a model that ignores the
  # ask and invents a business domain would leave the page saying something
  # untrue about deployed code. `source` is the trace RealSource.last_seen_for
  # reads back: code_review_mode itself is never persisted, so this is the
  # only record of what was grounded. A toy day needs no deletion here —
  # strip_server_stamps! has already removed whatever the provider put there,
  # or a model that happened to emit a `source` key would mint a trace for an
  # excerpt this set never showed. `current_schema` is server-owned the same
  # way, so it is stamped only from a source that has one; every provider copy
  # is already gone by now (see strip_current_schemas!).
  # In production code_review is always present — ExerciseSection.for_plan
  # never omits it — but ingest is also called on partial sets, and a set
  # with no code_review has no trace to stamp.
  def ground_code_review!
    return if @code_review_source.nil?
    return unless ExerciseSection.present?(@problem_set, "code_review")

    section = @problem_set["code_review"]
    section["scenario"] = @code_review_source.scenario
    section["source"]   = @code_review_source.id

    schema = @code_review_source.current_schema
    section["current_schema"] = schema if schema
  end

  # See SERVER_STAMPS. Stripped from every section, because an unrequested one
  # can still win its slot by list precedence — the same shape as
  # strip_current_schemas!. Runs before ground_code_review!, which stamps the
  # grounded day's `source` back on.
  def strip_server_stamps!
    @problem_set.each_value do |section|
      next unless section.is_a?(Hash)

      SERVER_STAMPS.each { |stamp| section.delete(stamp) }
    end
  end

  # Stamps every section a rung is known for, requested or not, since the
  # rendered set is resolved by precedence over what came back. `eased` is
  # stamped after the concept is known, since it depends on which concept the
  # model chose, and only ever as true. It records one thing: the prompt's
  # `(reduced)` rule was asked for here. It does not claim the rung was
  # otherwise pitched as stated — the prompt's rating adjustments can move an
  # unlocked section too, and the model decides when they apply, so the
  # server cannot record that. Runs after normalize_concepts!, so the concept
  # compared is the one the set will carry.
  def stamp_pitched_rungs!
    return if @pitched_at.nil?

    @problem_set.each do |key, section|
      next unless section.is_a?(Hash) && @pitched_at.key?(key)

      section["pitched_at"] = @pitched_at.fetch(key)
      section["eased"] = true if @eased_for.fetch(key, []).include?(section["concept"])
    end
  end

  # Runs on resolved sections only, after reject_unusable_sections! has
  # accepted them, for the same reason that step does.
  def arrange_sections!
    ExerciseSection.resolved_keys(@problem_set).each do |key|
      ExerciseSection.for(key).arrange!(@problem_set[key])
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
