# Design notes: docs/code-notes/app/services/generation_prompt.md
class GenerationPrompt
  include GenerationPrompt::ConceptGuidance

  def initialize(user, language, plan:, history:, difficulty:, ladders:, retention_annotation:)
    @user                 = user
    @language             = language
    @plan                 = plan
    @history              = history
    @difficulty           = difficulty
    @ladders              = ladders
    @retention_annotation = retention_annotation
  end

  def render(only: nil, fixed_concept: nil)
    kinds = kinds_for(only)
    rungs = @difficulty.rungs_for(kinds, skill_level: @user.skill_level)

    <<~PROMPT
      Generate a daily Code Gym exercise set for this engineer.

      Engineer profile:
      - Name: #{profile_name}
      - Skill level: #{@user.skill_level} (#{User::SKILL_LEVELS.join(" → ")})
      - Priority focus areas: #{focus}

      Recent performance (last 10 sessions):
      #{history_text}

      Concepts needing reinforcement right now: #{annotated_concepts(@plan.reinforcement)}
      #{fourth_reinforcement_line}

      Instructions:
      - If they've been rating exercises "too easy", increase difficulty and reduce explanation in the reference.
      - If they've been rating "too hard" or skipping sections, simplify and add more scaffolding.
      - Prioritize focus areas they've missed or rated hard recently.
      - Rotate between topics across sessions — avoid the same pattern two days in a row.
      - Vary the concrete business-domain scenario and code structure across sessions, not just the concept — do not reuse the class/method names or narrative framing shown in the "framings:" notes above.
      #{ts_guidance}
      #{scenario_flavor_guidance(@plan.scenario_flavor)}
      - Each teaching_note must point toward how to think about the problem or the right question to ask — one or two sentences, never the full answer.
      - answer_scaffold (#{scaffolded_kinds_clause} only): #{ExerciseSection::MAX_SCAFFOLD_LABELS} labels at most, #{ExerciseSection::MAX_SCAFFOLD_LABEL_LENGTH} characters at most each, ending in a colon. These pre-fill the answer box, so write them for THIS question specifically — name the parts a complete answer to it must cover, in the order someone should think them through (e.g. for a caching decision: "Which option, and why:", "How you'd handle a stale entry:"). Generic prompts that would fit any question of this kind are a wasted scaffold. Each is a heading the engineer writes UNDER, so it must ask for something, never state or hint at the answer — the teaching_note rules apply here too.
      - Every "diagram" field is Mermaid source using ONLY `flowchart TD` or `graph LR`. Maximum 8 nodes. No styling directives, no subgraphs, no click handlers, no classDef — narrow syntax parses reliably, clever syntax does not. Node labels must be short (a few words); use quoted labels like A["Order service"] when a label contains spaces or punctuation.
      - A section's "diagram" depicts ONLY the structure its scenario or snippet already describes — the components, calls, state, and consumers as written, in the order they happen. Never diagram the fix, the corrected structure, or the answer, and never annotate a node as the problem, the bug, or the bottleneck. The engineer sees this BEFORE answering, so showing the shape of a problem must never reveal its solution.
      - When the snippet or scenario contains a loop, iteration, or repeated invocation that wraps the flow being diagrammed (e.g. a method called inside `each`/`for`/`while`), the diagram must make that repetition visible — either an explicit loop/iteration node in the call's path, or a labeled edge stating the per-item cardinality (e.g. "once per customer", "for each order"). A flat one-time call chain is not accurate for code that actually repeats. Do not manufacture a loop or cardinality label when the snippet has none.
      - Return an empty string for any "diagram" when a picture would not add anything beyond the text. An empty string is a perfectly good answer and is preferred over a forced or trivial diagram.
      #{sections_guidance(kinds, rungs)}
      #{data_modeling_idiom_guidance}
      #{meta_skill_framing_guidance}
      #{code_smell_naming_guidance}
      #{oo_design_violation_guidance}
      #{module_design_depth_guidance}
      #{silent_correctness_guidance}
      #{domain_modeling_guidance}
      - Reduced-tier concepts: for any concept whose annotation includes `reduced` (alone or as `(reduced, drilled)`), keep the SAME concept and vocabulary — never silently swap in a different, easier concept. Ease the difficulty only: simpler framing, a smaller scenario, more scaffolding/starter code, and a teaching_note that guides more directly toward the key insight (it may name the technique, but not the full answer).
      - Mastery loop: reintroduce every concept listed as "needing reinforcement right now" above (both standard and reduced tiers) with a fresh code example and framing — never a repeat snippet. A concept exits reinforcement only on full mastery: the user's self-rating for that section was "right level"/"too easy" AND the AI rated it "solid"/"strong". Short of that, steady improvement (a better AI rating than last time) still counts as progress — keep reinforcing, and let the tier annotation tell you how hard to pitch it.
      - Drilled concepts: a concept marked `drilled` is one the engineer asked to practise on purpose, not one the ratings flagged. Include it exactly as you would any other concept needing reinforcement, with fresh framing. Its difficulty comes only from its tier annotation and the section's level — `drilled` on its own never eases or raises anything.#{fixed_concept_line(fixed_concept)}#{shared_concept_line(only)}
      #{retention_block(kinds, rungs)}
      #{established_block}
      #{fourth_retention_block}
      #{fourth_established_block}#{DifficultyGuidance.render(rungs: rungs, difficulty: @difficulty, ladders: @ladders)}
      - Concepts most recently rated "too easy" must not repeat within the same week.
      - Concepts most recently rated "right level" have no special weighting.

      Return JSON matching this schema exactly:
      #{schema(only: only)}
    PROMPT
  end

  def schema(only: nil)
    label = config[:label]

    sections = kinds_for(only).map { |kind| kind.schema_fragment(label: label) }
                              .join(",\n  ")

    <<~SCHEMA
      {
        #{sections}
      }
    SCHEMA
  end

  private

  def config = AiService.config_for(@language)

  def kinds_for(only)
    only ? [ only ] : ExerciseSection.for_plan(third: @plan.third, fourth: @plan.fourth, pattern: @plan.pattern)
  end

  def profile_name
    UserText.tagged(@user.name, blank: "(not given)", inline: true, limit: UserText::MAX_NAME_LENGTH)
  end

  def focus
    @user.focus_areas.any? ? @user.focus_areas.join(", ") : "general #{config[:label]} patterns"
  end

  def history_text
    return "No history yet — this is their first exercise set." if @history.empty?

    @history.map { |h| history_line(h) }.join("\n")
  end

  def history_line(h)
    pairs        = concept_pairs(h)
    concept_text = pairs.any? ? " | #{pairs.join(', ')}" : ""
    framings     = h[:scenarios].presence || []
    framing_text = framings.any? ? " | framings: #{framings.join('; ')}" : ""
    "#{h[:date]}: #{h[:sections_answered]}/#{h[:sections_total]} answered#{concept_text}#{framing_text}"
  end

  def concept_pairs(h)
    return [] unless h[:concepts].respond_to?(:each_pair)

    h[:concepts].each_pair.filter_map do |section, concept|
      next if concept.blank?
      self_r  = h[:self_ratings][section].presence || "unrated"
      skipped = h[:answered_sections] && !h[:answered_sections].include?(section)
      ai_r    = skipped ? "skipped" : (h[:ai_ratings][section].presence || "unreviewed")
      "#{section}→#{concept} (self: #{self_r}, ai: #{ai_r})"
    end
  end

  def annotated_concepts(entries)
    entries.any? ? entries.map { |h| annotate_reinforcement(h) }.join(", ") : "none"
  end

  def annotate_reinforcement(entry)
    "#{entry[:concept]} (#{[ entry[:tier], ("drilled" if entry[:drilled]) ].compact.join(', ')})"
  end

  def fourth_reinforcement_line
    return "" unless @plan.fourth

    "Fourth-section (#{@plan.fourth}) concept needing reinforcement: #{annotated_concepts(@plan.fourth_reinforcement)}"
  end

  def retention_block(kinds, rungs)
    annotated_due_checks = @plan.due_checks.filter_map do |cm|
      @retention_annotation.call(cm, kinds, @language, @plan.code_review_mode, rungs)
    end
    return "" if annotated_due_checks.none?

    <<~RET.chomp

      Retention checks due today: #{annotated_due_checks.join(', ')}
      - These are concepts the engineer previously MASTERED. Each is annotated with the section(s) it may occupy — work it into one of those in the schema below, alongside the reinforcement concepts.
      - Use a completely FRESH scenario for these — a new business domain, new class and method names, a new narrative. Never reuse any framing listed above. This tests whether they retained the idea, not whether they recognize a memorized example.
      - Pitch these at FULL difficulty. Do NOT ease them, add scaffolding, or write a more direct teaching_note the way you would for a `(reduced)` concept — the engineer is not struggling with these, and making them easier defeats the point of checking.
    RET
  end

  def established_block
    return "" if @plan.established.none?

    <<~EST.chomp

      Established concepts (well past first mastery — survived a retention check): #{@plan.established.map(&:concept).join(', ')}
      - If you were already going to select one of these for a section's concept, keep that section's teaching_note minimal (a single short sentence, or an empty string is fine).
      - Pitch at full difficulty — do not ease, simplify, or add scaffolding for these, the same as you would not for a retention check.
      - This is advisory, like every other concept instruction here: it does not force you to select one of these concepts, only shapes the section if you do.
    EST
  end

  def fourth_retention_block
    return "" if @plan.fourth_due_checks.none?

    <<~RET.chomp

      Retention check due for the fourth section today: #{@plan.fourth_due_checks.map(&:concept).join(', ')} (#{@plan.fourth} bucket).
      - This is a concept the engineer previously MASTERED in this skill. Work it into the fourth section as its concept.
      - Use a completely FRESH scenario — never reuse a prior framing. Pitch at FULL difficulty, no extra scaffolding — the engineer is not struggling with this, making it easier defeats the point of checking.
    RET
  end

  def fourth_established_block
    return "" if @plan.fourth_established.none?

    <<~EST.chomp

      Established fourth-section concept (well past first mastery, survived a retention check): #{@plan.fourth_established.map(&:concept).join(', ')}
      - If you were already going to select this for the fourth section's concept, keep the teaching_note minimal and pitch at full difficulty, the same as you would for any other established concept.
    EST
  end

  def ts_guidance
    return "" unless @language == "javascript"

    "- If a section's tagged concept is one of #{ConceptVocabulary::TYPESCRIPT_FLAVORED_CONCEPTS.join(", ")}, write that section's code using real TypeScript syntax and type annotations. Every other section stays plain JavaScript — do not switch the whole set to TypeScript just because one section calls for it.\n"
  end

  def fixed_concept_line(fixed_concept)
    return "" unless fixed_concept

    "\n- This section's concept must be exactly `#{fixed_concept}`: it replaces a section that was rejected on wording alone, and the day's plan already placed this concept here."
  end

  def shared_concept_line(only)
    only ? "" : shared_concept_guidance(@plan.shared_concept)
  end

  def shared_concept_guidance(concept)
    return "" if concept.nil?

    sections = ExerciseSection.fixed.map(&:key).to_sentence
    "\n- The #{sections} sections share `#{concept}` as their concept today. It is one concept needing reinforcement, looked at from different sides: each section tests it in its own way and its own scenario, following its own rules above."
  end

  def scenario_flavor_guidance(flavor)
    pool    = AiService::SCENARIO_POOLS.fetch(flavor)
    flavors = (pool[:domains] - %w[legacy_graphql_maintenance]).map { |d| d.tr("_", " ") }.join(", ")

    [
      "- Prefer drawing each section's business-domain scenario from #{pool[:intro]} like: #{flavors} " \
        "(adapt any flavor to fit the day's stack — e.g. #{pool[:adaptation]}).",
      pool[:rule],
      pool[:legacy]
    ].compact.join(" ")
  end

  def scaffolded_kinds_clause
    ExerciseSection.all.select(&:scaffolded?).map(&:key).to_sentence(last_word_connector: " and ")
  end

  def sections_guidance(kinds, rungs)
    kinds.map { |kind|
      generation_guidance_for(kind, @language, mode: @plan.code_review_mode, source: @plan.code_review_source, rung: rungs[kind])
    }.join("\n")
  end

  def generation_guidance_for(kind, language, mode: nil, source: nil, rung: nil)
    config = AiService.config_for(language)

    kind.generation_guidance(
      vocabulary:     ConceptVocabulary.selectable_for_section(kind.key, language, mode: mode, rung: rung),
      label:          config[:label],
      mode:           mode,
      artifact:       config[:schema_artifact],
      test_framework: config[:test_framework],
      source:         source,
      rung:           rung
    )
  end
end
