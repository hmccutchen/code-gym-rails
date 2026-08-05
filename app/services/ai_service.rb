require "json"

class AiService
  class Error < StandardError; end

  # Bad/revoked API key (HTTP 401/403) — user-actionable: they need to fix
  # their key in Settings. Never worth retrying.
  class AuthenticationError < Error; end

  # Transient rate limiting (HTTP 429) that survived Faraday's own retries.
  # User-actionable in the sense of "try again shortly", but not a bug.
  class RateLimitError < Error; end

  # Malformed JSON or a payload with the wrong shape (e.g. an Array where a
  # Hash was expected). Not user-actionable — almost always a real bug in
  # our prompt/schema or a provider-side change.
  class InvalidResponseError < Error; end

  # The provider stopped generating because it hit its output token cap, so
  # the JSON body is syntactically incomplete. Detected explicitly because
  # otherwise it surfaces as a generic parse error ("unexpected end of
  # input"), which points at the wrong cause — the payload isn't malformed,
  # it's unfinished.
  class TruncatedResponseError < InvalidResponseError; end

  # Fixed concept vocabularies, one per generation language. Embedded in the
  # generation prompt; anything a provider returns outside the active list is
  # normalized to "other" so per-user concept history stays aggregatable.
  # Kept closed rather than AI-extensible so history stays clean.
  #
  # Security concepts are deliberately selective: the mastery-tier system
  # (Standard/Reduced/Paused, easing/reinforcing over time) only pays off for
  # concepts with real depth — room to be approached multiple ways, room to
  # get harder or easier. Two proposed security items were cut for lacking
  # that depth: `secure_secrets_handling` is essentially one rule ("don't
  # hardcode credentials") with no harder version to graduate toward, and
  # `dependency_vulnerability_management` is a process/tooling habit (running
  # an audit tool, reviewing a Dependabot PR) that no code snippet can test —
  # the wrong shape for this app's format entirely.
  RAILS_CONCEPTS = %w[
    n_plus_one transaction_safety memoization service_objects scope_chaining
    idempotency authorization background_jobs caching validations
    callbacks_vs_service query_objects policy_objects indexing concurrency
    error_handling mass_assignment_protection sql_injection_prevention
    over_mocking testing_implementation_not_behavior
  ].freeze

  JS_CONCEPTS = %w[
    callback_hell promise_chaining closures prototype_chain event_loop_blocking
    this_binding array_mutation_pitfalls debouncing_throttling closures_in_loops
    memory_leaks_listeners hooks_dependencies component_re_renders state_lifting
    controlled_vs_uncontrolled xss_prevention insecure_client_storage
    generics type_guards_narrowing union_intersection_types mapped_conditional_types
    over_mocking testing_implementation_not_behavior
  ].freeze

  # The exact subset security_review draws from — never the full language
  # vocabulary. Each concept gets reinforced through two reasoning modes on
  # different days: "is this correct" (code_review) and "is this exploitable"
  # (security_review). A restricted list is what makes that interleaving
  # deliberate rather than incidental — without it, security_review could
  # surface an unrelated concept like memoization under adversarial framing.
  RAILS_SECURITY_CONCEPTS = %w[mass_assignment_protection sql_injection_prevention].freeze
  JS_SECURITY_CONCEPTS    = %w[xss_prevention insecure_client_storage].freeze

  # Subset of JS_CONCEPTS that reflects real TypeScript usage rather than a
  # separate language mode: no new generation language, no schema change.
  # When one of these is the section's tagged concept, build_exercise_prompt
  # instructs real TS syntax/annotations for that section only — every other
  # JS_CONCEPTS entry stays plain JS, matching actual day-to-day variety.
  TYPESCRIPT_FLAVORED_CONCEPTS = %w[
    generics type_guards_narrowing union_intersection_types mapped_conditional_types
  ].freeze

  # Language-INDEPENDENT architecture/design-reasoning vocabulary. Unlike
  # RAILS_CONCEPTS/JS_CONCEPTS this is NOT tied to the user's language: these
  # concepts transcend any one stack. Used only by the architecture third
  # section and its concept references (pseudo-language "architecture").
  ARCHITECTURE_CONCEPTS = %w[
    sync_vs_async service_boundaries coupling_cohesion data_consistency_tradeoffs
    caching_strategy build_vs_buy scaling_bottlenecks failure_mode_design
    api_versioning event_driven_vs_request_response data_ownership
    idempotency_at_scale observability_tradeoffs
  ].freeze

  # Curated, real, job-adjacent scenario flavors for the "scenario" field's
  # business-domain framing — prompt-level grounding only, to keep generated
  # scenarios feeling like real engineering work rather than generic SaaS
  # examples. Never concept-tagged, never fed into concept_vocabulary_for or
  # any mastery-loop bucket. `legacy_graphql_maintenance` is scenario dressing
  # only, for occasional legacy-app relevance — see build_exercise_prompt's
  # explicit low-frequency instruction. It must never appear as a "concept"
  # value.
  SCENARIO_DOMAINS = %w[
    background_job_processing api_versioning_and_deprecation
    activerecord_query_construction component_state_management
    data_export_and_reporting webhook_delivery rate_limiting
    multi_tenant_data_isolation legacy_graphql_maintenance
  ].freeze

  # Single source of truth per concrete generation language ("mixed" is a
  # user-level meta-preference that always resolves to one of these before it
  # reaches AiService — see User#language_for_today). Adding a language means
  # adding one entry here, not hunting down every ternary in this file.
  LANGUAGE_CONFIG = {
    "ruby_rails" => {
      label:             "Ruby/Rails",
      concepts:          RAILS_CONCEPTS,
      security_concepts: RAILS_SECURITY_CONCEPTS,
      coach:             "Rails",
      test_framework:    "an RSpec-style",
      focus:             "real Rails patterns: N+1 queries, idempotency, background jobs, authorization, service objects, query objects, policy objects."
    },
    "javascript" => {
      label:             "JavaScript/React",
      concepts:          JS_CONCEPTS,
      security_concepts: JS_SECURITY_CONCEPTS,
      coach:             "JavaScript/React",
      test_framework:    "a Jest/Vitest-style",
      focus:             "real JavaScript/React patterns: closures, async/event-loop pitfalls, prototypal inheritance, `this` binding, and hooks/re-renders."
    },
    "architecture" => {
      label:    "language-agnostic",
      concepts: ARCHITECTURE_CONCEPTS,
      coach:    "software architecture",
      focus:    "system-design tradeoffs: service boundaries, consistency, failure modes, scale, coupling."
    }
  }.freeze

  CONCEPT_REFERENCE_FIELDS = %w[tagline explanation code_example senior_lens].freeze

  # Max bytes of raw provider output logged server-side when a provider
  # response can't be used (invalid JSON, non-success HTTP status). Keeps
  # exception messages — which surface in flash alerts and error trackers —
  # free of large/undesired provider content.
  RAW_SNIPPET_LIMIT = 500

  def initialize(api_key)
    @api_key = api_key
    @conn    = build_connection
  end

  # ── Dispatch to the right provider for this user ─────────────────────────
  # "fake" is never reachable through the app — ApiKeysController derives
  # provider from a two-entry key-format allowlist — so a fake-provider user in
  # production could only come from a console/DB mistake, where silently serving
  # canned exercises would be worse than failing loudly.
  def self.for(user)
    case user.provider
    when "anthropic" then ClaudeService.new(user.api_key)
    when "gemini"    then GeminiService.new(user.api_key)
    when "fake"
      raise Error, "User #{user.id} has the test-only fake provider outside a local environment" unless Rails.env.local?

      FakeService.new(user.api_key)
    else
      raise Error, "User #{user.id} has no recognized AI provider configured"
    end
  end

  # ── Generate a personalized daily exercise set ────────────────────────────
  # The day's plan (third section, reinforcement, retention checks) is decided by
  # DailyPlan before any provider is contacted; this method only renders it into
  # a prompt, sends it, and records what came back.
  def generate_exercise(user, language: user.language_for_today)
    plan = DailyPlan.for(user, language: language)

    result = call_and_log(
      user, purpose: "generate_exercise",
      system: build_system_prompt(language),
      prompt: build_exercise_prompt(user, language, third: plan.third,
                                    reinforcement: plan.reinforcement, due_checks: plan.due_checks,
                                    established: plan.established)
    )

    problem_set = normalize_concepts(parse_json_object(result[:text], subject: "problem set"), language)
    shuffle_parsons_blocks!(problem_set)
    log_retention(user, language, plan.due_checks, problem_set)
    problem_set
  end

  # ── Review a submitted response, one thread per still-missing section ────
  # Each thread gets its own service instance (and therefore its own Faraday
  # connection) — no shared mutable state crosses a thread boundary. A
  # section's failure is caught and tagged rather than raised, so one bad
  # section can never keep the other threads' results from being usable by
  # the caller.
  def review_sections(user, exercise, daily_response, sections:)
    coach   = config_for(exercise.language)[:coach]
    context = build_review_day_context(coach, exercise, daily_response)

    threads = sections.map do |section|
      Thread.new do
        service = self.class.new(@api_key)
        begin
          result = service.send(
            :call_and_log, user, purpose: "review_response",
            system: context, prompt: service.send(:build_review_section_prompt, exercise, daily_response, section),
            cache_system: true
          )
          review = service.send(:parse_json_object, result[:text], subject: "#{section} review")
          review = service.send(:override_parsons_section_rating!, review, exercise, daily_response) if section == "parsons_problem"
          [ section, { ok: true, review: review } ]
        rescue AiService::Error => e
          [ section, { ok: false, error_code: error_code_for(e), message: e.message } ]
        end
      end
    end

    threads.map(&:value).to_h
  end

  # ── Generate the one-time cached reference for a single concept ───────────
  def generate_concept_reference(user, concept, language)
    config = config_for(language)

    result = call_and_log(
      user, purpose: "generate_concept_reference",
      system: "You are a senior #{config[:coach]} engineer writing a concise, durable reference for one concept. Return ONLY valid JSON.",
      prompt: build_concept_reference_prompt(concept, config)
    )

    reference = parse_json_object(result[:text], subject: "concept reference")

    # Caching keys off (concept, language), so a row missing any field would
    # persist a partially-blank reference forever and block regeneration.
    # Failing here lets the job swallow it and retry on the next submission.
    missing = CONCEPT_REFERENCE_FIELDS.reject { |field| reference[field].to_s.strip.present? }
    if missing.any?
      raise InvalidResponseError, "Concept reference missing required field(s): #{missing.join(', ')}"
    end

    reference
  end

  # ── Reframe one section's feedback a different way ───────────────────────
  # Returns a plain string, not JSON: there is no structure to parse, and routing
  # it through parse_json_object would add a failure mode for no benefit.
  def explain_differently(user, exercise, daily_response, section:, prior_alternates: [])
    coach   = config_for(exercise.language)[:coach]
    review  = daily_response.ai_review&.dig(section) || {}
    missed  = DailyResponse.review_points(review["missed"])

    prior = if prior_alternates.any?
      "Framings already given (do NOT reprise these angles or analogies):\n" +
        prior_alternates.map.with_index(1) { |a, i| "#{i}. #{a}" }.join("\n")
    else
      "No alternate framing has been given yet."
    end

    result = call_and_log(
      user, purpose: "explain_differently",
      system: "You are a senior #{coach} engineer re-explaining one point to an engineer who did not follow the first explanation. Return plain prose — no JSON, no markdown fences.",
      prompt: <<~PROMPT
        The engineer was asked: #{exercise.problem_set.dig(section, "question")}
        Their answer: #{daily_response.answers[section].presence || "(skipped)"}

        What they missed:
        #{missed.any? ? missed.map { |m| "- #{m}" }.join("\n") : "- (nothing recorded)"}

        #{prior}

        Explain the SAME point again using a genuinely different approach — a
        different analogy, a different level of abstraction, or a concrete worked
        scenario instead of a principle. Do not repeat the original wording.
        Two short paragraphs at most.
      PROMPT
    )

    text_or_raise(result, subject: "alternate explanation")
  end

  # ── Answer one follow-up question about a completed review ────────────────
  # `thread` is an ordered array of { role:, content: } hashes — the prior turns
  # for this section. Returns plain prose, like #explain_differently.
  def answer_follow_up(user, exercise, daily_response, section:, question:, thread: [])
    coach  = config_for(exercise.language)[:coach]
    review = daily_response.ai_review&.dig(section) || {}

    review_summary = DailyResponse::AI_REVIEW_FIELDS.filter_map { |key, field|
      points = DailyResponse.review_points(review[key])
      "#{field[:label]}: #{points.join('; ')}" if points.any?
    }.join("\n")

    thread_text = thread.any? ?
      thread.map { |turn| "#{turn[:role] == 'assistant' ? 'You' : 'Them'}: #{turn[:content]}" }.join("\n") :
      "(no prior questions)"

    result = call_and_log(
      user, purpose: "review_follow_up",
      system: "You are a senior #{coach} engineer answering a follow-up question about feedback you already gave. Be direct and concrete. Return plain prose — no JSON, no markdown fences.",
      prompt: <<~PROMPT
        The original exercise asked: #{exercise.problem_set.dig(section, "question")}
        Their answer was: #{daily_response.answers[section].presence || "(skipped)"}

        The review you gave:
        #{review_summary.presence || "(no detail recorded)"}

        Conversation so far:
        #{thread_text}

        Their new question: #{question}

        Answer it directly. Stay on this concept — if they drift far off topic, say
        so briefly and bring it back. Two short paragraphs at most.
      PROMPT
    )

    text_or_raise(result, subject: "follow-up answer")
  end

  private

  # A blank provider response is a provider bug, not a valid answer — persisting
  # it downstream fails a presence validation with an error class that escapes
  # the controller's `rescue AiService::Error`, so the user gets a raw 500
  # instead of the clean "couldn't generate that" message every other failure
  # gets. Raising here routes it through the same handling as any other bad
  # provider response.
  def text_or_raise(result, subject:)
    text = result[:text].to_s.strip
    raise InvalidResponseError, "Provider returned an empty #{subject}" if text.blank?
    text
  end

  def error_code_for(error)
    case error
    when AuthenticationError  then "authentication"
    when RateLimitError       then "rate_limit"
    when InvalidResponseError then "invalid_response"
    else                           "other"
    end
  end

  # Looks up the fixed per-language config, failing loudly on anything
  # outside RAILS_CONCEPTS/JS_CONCEPTS's languages (e.g. "mixed", or a typo)
  # instead of silently degrading to Ruby/Rails behavior.
  def config_for(language)
    LANGUAGE_CONFIG.fetch(language) do
      raise Error, "Unsupported generation language: #{language.inspect}"
    end
  end

  # A due retention concept's `language` bucket names which vocabulary it was
  # validated against, but not which section(s) that vocabulary is legal in
  # today — without this the model has no way to know an architecture-vocabulary
  # concept can't go in code_review, guesses wrong, and normalize_concepts
  # rewrites a correctly-honored check into a false "miss". A language-bucket
  # concept is legal in challenge always, but in security_review only when
  # it's one of that language's security_concepts (RAILS_SECURITY_CONCEPTS/
  # JS_SECURITY_CONCEPTS) — security_review draws from that restricted list
  # exclusively, so any other concept can only land in code_review/pattern.
  def annotate_retention_concept(cm, third)
    if cm.language == "architecture"
      "#{cm.concept} (architecture section)"
    elsif third == :architecture
      "#{cm.concept} (code_review or pattern)"
    elsif third == :security_review && !config_for(cm.language)[:security_concepts].include?(cm.concept)
      "#{cm.concept} (code_review or pattern)"
    else
      "#{cm.concept} (code_review, pattern, or #{third})"
    end
  end

  # A provider can return a parsons_problem object with no "blocks" — that
  # still resolves as the third section (third_key only checks for a Hash), but
  # there is nothing to score against, so the prompt must not claim a verified
  # count. Grading is skipped entirely in that case rather than reporting the
  # grader's degenerate "0 out of place".
  def parsons_review_block(parsons, answer)
    blocks = Array(parsons["blocks"])
    header = "Parsons Problem (#{parsons["title"]}): #{parsons["question"]}"

    if blocks.empty?
      return <<~UNVERIFIED.chomp
        #{header}
        This section's blocks are missing from the stored exercise, so the submitted ordering CANNOT be verified. Do not state or imply how many blocks were misplaced, and do not rate this section's correctness — say only that the exercise data is unavailable.
        For this section "improved_code" must be an empty string.
      UNVERIFIED
    end

    submitted = ExerciseSection::ParsonsProblem.parse_order(answer)
    graded    = ExerciseSection::ParsonsProblem.grade(submitted, blocks.size)

    <<~PARSONS.chomp
      #{header}
      Correct blocks, in order: #{blocks.each_with_index.map { |b, i| "#{i + 1}. #{b}" }.join(" / ")}
      What they misplaced: #{describe_parsons_mismatches(blocks, submitted)}
      Verified result (already scored in Ruby — do not re-judge correctness or propose a different rating): #{graded[:mismatches]} block(s) out of place.

      Explain WHY the misplaced blocks belong where they do — cite the actual dependency or logical reason (e.g. "this block uses a variable an earlier block declares, so it must come after it"), grounded strictly in the verified result above. Do not output a "rating" judgement of your own for this section; the rating is fixed by the verified result, not by you.
      For this section "improved_code" must be an empty string.
    PARSONS
  end

  # The ground truth the review prompt hands the model, so it explains a known
  # result rather than judging one. Padding mirrors ParsonsProblem.grade so a
  # short or skipped submission describes rather than raises.
  def describe_parsons_mismatches(blocks, submitted_ids)
    return "cannot verify — the exercise's blocks are unavailable" if blocks.empty?
    padded = Array.new(blocks.size) { |i| submitted_ids[i] }
    descriptions = padded.each_index.filter_map { |i|
      next if padded[i] == i
      got = ExerciseSection::ParsonsProblem.valid_id?(padded[i], blocks.size) ? "\"#{blocks[padded[i]]}\"" : "(nothing submitted)"
      "position #{i + 1} has #{got} (correct block there: \"#{blocks[i]}\")"
    }
    descriptions.any? ? descriptions.join("; ") : "exact match — no blocks misplaced"
  end

  # Delivery is advisory, so the only way to know whether retention checks actually
  # land is to record both halves. Logged after normalize_concepts so it reflects
  # the concepts actually persisted, not whatever the provider first returned.
  # `tagged` makes a miss diagnosable rather than merely countable: it shows what
  # the model picked instead.
  def log_retention(user, language, due_checks, problem_set)
    return if due_checks.empty?

    offered = due_checks.map(&:concept)
    tagged  = problem_set.values.filter_map { |s| s["concept"] if s.is_a?(Hash) }
    honored = offered & tagged

    Rails.logger.info(
      "[retention] user=#{user.id} date=#{Date.current} language=#{language} " \
      "offered=#{offered.join(',').presence || '-'} " \
      "honored=#{honored.join(',').presence || '-'} " \
      "tagged=#{tagged.join(',').presence || '-'}"
    )
  end

  # Subclasses must implement: makes the provider-specific HTTP call and
  # returns a normalized Hash { text:, input_tokens:, output_tokens: }.
  def call(system:, prompt:, cache_system: false)
    raise NotImplementedError, "#{self.class} must implement #call"
  end

  # Subclasses must implement: returns a configured Faraday::Connection.
  def build_connection
    raise NotImplementedError, "#{self.class} must implement #build_connection"
  end

  def build_system_prompt(language = "ruby_rails")
    config = config_for(language)

    <<~PROMPT
      You are a senior #{config[:coach]} engineering coach generating personalized daily exercise sets.
      Your goal is to push engineers toward senior-level thinking: not just "what" but "why" and "when not to."
      Focus on #{config[:focus]}
      Return ONLY valid JSON — no markdown fences, no explanation outside the JSON.
    PROMPT
  end

  # JSON schema every provider is asked to return for a problem set. The
  # code-bearing fields' label switches with `language` so instructions never
  # assume Ruby idioms when generating JS — the structure itself never
  # changes across languages.
  def exercise_schema_for(language = "ruby_rails", third: :challenge)
    label = config_for(language)[:label]
    glossary_field = %("glossary": [{"term": "string — an unfamiliar word from this section's own text", "definition": "string — one plain-English sentence"}])

    third_section =
      case third
      when :architecture
        <<~ARCH.chomp
          "architecture": {
              "title":     "string — short name for the decision",
              "scenario":  "string — 2-3 sentences, ~50 words max. Exactly 2-3 concrete constraints total, no more",
              "question":  "string — ONE sentence asking for a decision + justification",
              "options":   ["string — a viable approach", "string — another viable approach", "string — an optional third approach (omit for 2)"],
              "teaching_note": "string — 1-2 sentence hint toward HOW to reason, never the answer",
              "concept": "string — exactly one concept from the architecture vocabulary",
              #{glossary_field},
              "reference": {
                "tagline":     "string — bold one-liner",
                "explanation": "string — 2-3 sentences",
                "tradeoffs":   ["string — a tradeoff", "string — a tradeoff", "string — a tradeoff"],
                "senior_lens": "string — how a senior frames the decision",
                "diagram":     "string — Mermaid source visualizing the decision, or an empty string if no diagram would help"
              }
            }
        ARCH
      when :security_review
        <<~SEC.chomp
          "security_review": {
              "title":        "string",
              "question":     "string — what security vulnerability exists here, and how would you mitigate it",
              "snippet":      "string — #{label} code, ~10-15 lines, containing one real, exploitable vulnerability",
              "scenario": "string — the concrete business-domain framing, e.g. 'inventory restocking service'",
              "teaching_note": "string — 1-2 sentence hint toward HOW to reason, never the answer",
              "concept": "string — exactly one concept from the provided vocabulary",
              #{glossary_field},
              "reference": {
                "tagline":      "string — bold one-liner",
                "explanation":  "string — 2-3 sentences",
                "code_example": "string — annotated #{label} code, ~15 lines",
                "senior_lens":  "string — when to reach for it / tradeoffs"
              }
            }
        SEC
      when :parsons_problem
        <<~PB.chomp
          "parsons_problem": {
              "title":    "string",
              "scenario": "string — the concrete business-domain framing, e.g. 'inventory restocking service'",
              "question": "string — e.g. 'Arrange these blocks into the correct working solution'",
              "blocks":   ["string — one logical line or short cohesive group of lines, IN THE CORRECT FINAL ORDER", "string — the next block in correct order", "... (5-8 blocks total)"],
              "teaching_note": "string — 1-2 sentence hint toward the key insight, never the answer",
              "concept": "string — exactly one concept from the provided vocabulary",
              #{glossary_field}
            }
        PB
      else
        <<~CH.chomp
          "challenge": {
              "title":        "string",
              "question":     "string — what to implement",
              "scenario": "string — the concrete business-domain framing, e.g. 'inventory restocking service'",
              "starter_code": "string — optional skeleton (empty string if none)",
              "teaching_note": "string — 1-2 sentence hint toward the key insight, never the answer",
              "concept": "string — exactly one concept from the provided vocabulary",
              #{glossary_field}
            }
        CH
      end

    <<~SCHEMA
      {
        "code_review": {
          "question": "string — what to find/fix",
          "snippet":  "string — #{label} code, ~10-15 lines",
          "teaching_note": "string — 1-2 sentence hint toward the key insight, never the answer",
          "concept": "string — exactly one concept from the provided vocabulary",
          "scenario": "string — the concrete business-domain framing, e.g. 'inventory restocking service'",
          #{glossary_field}
        },
        "pattern": {
          "title":    "string — pattern name",
          "why":      "string — one sentence on why the pattern exists",
          "question": "string — conceptual question to answer. Must be fully self-contained: never reference a code snippet, example, or \\\"the code below\\\" — none is shown for this section.",
          "scenario": "string — the concrete business-domain framing, e.g. 'inventory restocking service'",
          "teaching_note": "string — 1-2 sentence hint toward the key insight, never the answer",
          "concept": "string — exactly one concept from the provided vocabulary",
          #{glossary_field}
        },
        #{third_section}
      }
    SCHEMA
  end

  def build_exercise_prompt(user, language = "ruby_rails", third: :challenge, reinforcement: nil, due_checks: [], established: [])
    history = user.recent_performance

    history_text = if history.empty?
      "No history yet — this is their first exercise set."
    else
      history.map { |h|
        pairs = h[:concepts].respond_to?(:each_pair) ? h[:concepts].each_pair.filter_map { |section, concept|
          next if concept.blank?
          self_r = h[:self_ratings][section].presence || "unrated"
          ai_r   = h[:ai_ratings][section].presence  || "unreviewed"
          "#{section}→#{concept} (self: #{self_r}, ai: #{ai_r})"
        } : []
        concept_text = pairs.any? ? " | #{pairs.join(', ')}" : ""
        framings     = h[:scenarios].presence || []
        framing_text = framings.any? ? " | framings: #{framings.join('; ')}" : ""
        feedback     = h[:feedback].present? ? " | Feedback: \"#{h[:feedback]}\"" : ""
        "#{h[:date]}: #{h[:sections_answered]}/3 answered#{concept_text}#{framing_text}#{feedback}"
      }.join("\n")
    end

    reinforcement_list = reinforcement || user.concepts_needing_reinforcement
    reinforcement_text = reinforcement_list.any? ?
      reinforcement_list.map { |h| "#{h[:concept]} (#{h[:tier]})" }.join(", ") : "none"

    # Advisory, like every other concept instruction here — the model may ignore it.
    # If real-world hit rate turns out low, the fix is to escalate THIS wording
    # toward the directive phrasing used for reinforcement above ("reintroduce
    # every concept listed"). It is not a reason to revisit the schedule, the data
    # model, or the decision not to track delivery.
    retention_block =
      if due_checks.any?
        <<~RET.chomp

          Retention checks due today: #{due_checks.map { |cm| annotate_retention_concept(cm, third) }.join(', ')}
          - These are concepts the engineer previously MASTERED. Each is annotated with the section(s) it may occupy — work it into one of those in the schema below, alongside the reinforcement concepts.
          - Use a completely FRESH scenario for these — a new business domain, new class and method names, a new narrative. Never reuse any framing listed above. This tests whether they retained the idea, not whether they recognize a memorized example.
          - Pitch these at FULL difficulty. Do NOT ease them, add scaffolding, or write a more direct teaching_note the way you would for a `(reduced)` concept — the engineer is not struggling with these, and making them easier defeats the point of checking.
        RET
      else
        ""
      end

    # Unlike retention_block, this never forces a selection — it only shapes a
    # section if the model was already going to pick one of these on its own.
    established_block =
      if established.any?
        <<~EST.chomp

          Established concepts (well past first mastery — survived a retention check): #{established.map(&:concept).join(', ')}
          - If you were already going to select one of these for a section's concept, keep that section's teaching_note minimal (a single short sentence, or an empty string is fine) and return an empty glossary array for that section.
          - Pitch at full difficulty — do not ease, simplify, or add scaffolding for these, the same as you would not for a retention check.
          - This is advisory, like every other concept instruction here: it does not force you to select one of these concepts, only shapes the section if you do.
        EST
      else
        ""
      end

    ts_guidance =
      if language == "javascript"
        "- If a section's tagged concept is one of #{TYPESCRIPT_FLAVORED_CONCEPTS.join(", ")}, write that section's code using real TypeScript syntax and type annotations. Every other section stays plain JavaScript — do not switch the whole set to TypeScript just because one section calls for it.\n"
      else
        ""
      end

    scenario_domain_list = (SCENARIO_DOMAINS - %w[legacy_graphql_maintenance]).map { |d| d.tr("_", " ") }.join(", ")

    config      = config_for(language)
    label       = config[:label]
    focus       = user.focus_areas.any? ? user.focus_areas.join(", ") : "general #{label} patterns"
    concepts    = config[:concepts]

    test_file_clause =
      if config[:test_framework].present?
        " Roughly 1 in 4 sessions, make it #{config[:test_framework]} test file exhibiting a real test smell instead — same question shape (\"what's the issue here, and how would you fix it\")."
      else
        ""
      end

    third_guidance =
      case third
      when :architecture
        <<~ARCH.chomp
          - The third section is an ARCHITECTURE decision, not a coding task. Present 2-3 viable options and ask for a decision plus justification. Its reference must center on tradeoffs (plural).
          - Keep the architecture scenario SHORT: 2-3 sentences, ~50 words maximum, and exactly 2-3 concrete constraints total. Usually the observable symptom plus one hard technical constraint is enough — pick only the constraints the decision actually turns on, and leave the rest out. Do NOT stack scale figures, team size, infrastructure detail, budget, and timeline into one scenario.
          - Short does not mean vague: name real numbers and real systems for the 2-3 constraints you do include. Fewer constraints, not fuzzier ones.
          - The architecture question itself is one sentence — do not restate the scenario in it.
          - Choose the code_review and pattern concepts from this vocabulary, exactly one each: #{concepts.join(", ")}
          - Choose the architecture section's concept from this SEPARATE vocabulary, exactly one: #{ARCHITECTURE_CONCEPTS.join(", ")}
          - The architecture reference's "diagram" must be valid Mermaid source using ONLY `flowchart TD` or `graph LR`. Maximum 8 nodes. No styling directives, no subgraphs, no click handlers, no classDef — narrow syntax parses reliably, clever syntax does not.
          - Node labels must be short (a few words). Use quoted labels like A["Order service"] when a label contains spaces or punctuation.
          - The diagram should show the STRUCTURE the decision is about — the services, data stores, and flows in tension — not a flowchart of how to decide.
          - Return an empty string for "diagram" when a picture would not add anything beyond the text. An empty string is a perfectly good answer and is preferred over a forced or trivial diagram.
        ARCH
      when :security_review
        <<~SEC.chomp
          - The third section is a SECURITY REVIEW, not a general correctness check. The snippet must contain one real, exploitable vulnerability appropriate to #{label}. The question asks the engineer to identify the vulnerability AND propose a mitigation — not just "what's wrong with this code."
          - Choose the security_review concept from this vocabulary, exactly one — these are the ONLY concepts security_review may use, never one from code_review/pattern's broader vocabulary: #{config[:security_concepts].join(", ")}
          - The security_review snippet should be realistic #{label} code, not a contrived toy example — the same bar as code_review's snippet.
        SEC
      when :parsons_problem
        <<~PB.chomp
          - The third section is a PARSONS PROBLEM: return "blocks" as 5 to 8 short code blocks IN THE CORRECT FINAL ORDER — the app shuffles them for display, you must never shuffle them yourself. Each block should be one coherent unit (a full line, or a short logically-grouped set of lines) — never a single token or a bare punctuation mark, since reordering individual tokens is busywork rather than the exercise.
          - Choose each section's concept from this fixed vocabulary, exactly one per section: #{concepts.join(", ")}
        PB
      else
        <<~CH.chomp
          - The challenge starter_code should give enough scaffold to get started without giving away the answer.
          - Choose each section's concept from this fixed vocabulary, exactly one per section: #{concepts.join(", ")}
        CH
      end

    <<~PROMPT
      Generate a daily Code Gym exercise set for this engineer.

      Engineer profile:
      - Name: #{user.name}
      - Skill level: #{user.skill_level} (beginner → developing → solid → strong)
      - Priority focus areas: #{focus}

      Recent performance (last 10 sessions):
      #{history_text}

      Concepts needing reinforcement right now: #{reinforcement_text}

      Instructions:
      - If they've been rating exercises "too easy", increase difficulty and reduce explanation in the reference.
      - If they've been rating "too hard" or skipping sections, simplify and add more scaffolding.
      - Prioritize focus areas they've missed or rated hard recently.
      - The code_review snippet must be realistic #{label} code — not toy examples.#{test_file_clause}
      - Rotate between topics across sessions — avoid the same pattern two days in a row.
      - Vary the concrete business-domain scenario and code structure across sessions, not just the concept — do not reuse the class/method names or narrative framing shown in the "framings:" notes above.
      #{ts_guidance}
      - Prefer drawing each section's business-domain scenario from real, job-adjacent flavors like: #{scenario_domain_list} (adapt any flavor to fit the day's stack — e.g. a Rails day's "component state management" becomes a service/controller state concern instead). Use a legacy GraphQL maintenance scenario (e.g. "a legacy GraphQL layer needs a fix") only rarely — at most roughly 1 in every 8-10 sessions — purely as scenario framing, never as the tagged concept.
      - Each teaching_note must point toward how to think about the problem or the right question to ask — one or two sentences, never the full answer.
      - Each section's "glossary": 0-4 {term, definition} pairs for incidental terminology inside THAT section's own title/scenario/question/why/options text that a mid-level developer newer to #{label} might not immediately know — distinct from the section's own tagged "concept" and from "teaching_note". One plain-English sentence per definition, same tone as the rest of this app's teaching content. Return an empty array when nothing in the section's text warrants one — never force entries to exist.
      #{third_guidance}
      - Reduced-tier concepts: for any concept marked `(reduced)`, keep the SAME concept and vocabulary — never silently swap in a different, easier concept. Ease the difficulty only: simpler framing, a smaller scenario, more scaffolding/starter code, and a teaching_note that guides more directly toward the key insight (it may name the technique, but not the full answer).
      - Mastery loop: reintroduce every concept listed as "needing reinforcement right now" above (both standard and reduced tiers) with a fresh code example and framing — never a repeat snippet. A concept exits reinforcement only on full mastery: the user's self-rating for that section was "right level"/"too easy" AND the AI rated it "solid"/"strong". Short of that, steady improvement (a better AI rating than last time) still counts as progress — keep reinforcing, and let the tier annotation tell you how hard to pitch it.
      #{retention_block}
      #{established_block}
      - Concepts most recently rated "too easy" must not repeat within the same week.
      - Concepts most recently rated "right level" have no special weighting.

      Return JSON matching this schema exactly:
      #{exercise_schema_for(language, third: third)}
    PROMPT
  end

  # Mirrors the pattern-section `reference` shape so both render identically.
  def build_review_day_context(coach, exercise, daily_response)
    answers = daily_response.answers
    ratings = daily_response.section_ratings

    <<~CONTEXT
      You are a senior #{coach} engineer giving direct, specific feedback on a junior/mid engineer's Code Gym answers. You will grade exactly one of the day's three sections in a follow-up instruction — the other two are given here only so your calibration of "developing" vs. "solid" stays consistent across the whole day. Be honest and constructive. Return JSON.

      Code Review question: #{exercise.code_review["question"]}
      Code snippet: #{exercise.code_review["snippet"]}
      Their answer: #{answers["code_review"].presence || "(skipped)"}
      Their self-rating: #{ratings["code_review"] || "(none given)"}

      Pattern question (#{exercise.pattern["title"]}): #{exercise.pattern["question"]}
      Their answer: #{answers["pattern"].presence || "(skipped)"}
      Their self-rating: #{ratings["pattern"] || "(none given)"}

      #{third_context_summary(exercise, answers, ratings)}
    CONTEXT
  end

  def third_context_summary(exercise, answers, ratings)
    case exercise.third_key
    when "architecture"
      arch = exercise.architecture
      "Architecture decision (#{arch["title"]}): #{arch["question"]}\n" \
      "Scenario/constraints: #{arch["scenario"]}\n" \
      "Their answer: #{answers["architecture"].presence || "(skipped)"}\n" \
      "Their self-rating: #{ratings["architecture"] || "(none given)"}"
    when "security_review"
      sec = exercise.security_review
      "Security Review (#{sec["title"]}): #{sec["question"]}\n" \
      "Snippet: #{sec["snippet"]}\n" \
      "Their answer: #{answers["security_review"].presence || "(skipped)"}\n" \
      "Their self-rating: #{ratings["security_review"] || "(none given)"}"
    when "parsons_problem"
      parsons = exercise.parsons_problem
      "Parsons Problem (#{parsons["title"]}): #{parsons["question"]}\n" \
      "Their self-rating: #{ratings["parsons_problem"] || "(none given)"}"
    else
      "Coding Challenge: #{exercise.challenge["question"]}\n" \
      "Their answer: #{answers["challenge"].presence || "(skipped)"}\n" \
      "Their self-rating: #{ratings["challenge"] || "(none given)"}"
    end
  end

  def build_review_section_prompt(exercise, daily_response, section)
    <<~PROMPT
      Grade ONLY the "#{section}" section from the day's context above.

      #{section_grading_note(exercise, daily_response, section)}

      Return a single JSON object (NOT wrapped in a "#{section}" key) with:
      - "rating": "beginner" | "developing" | "solid" | "strong"
      - "correct": array of strings — each entry one distinct thing they got right
      - "missed": array of strings — each entry one distinct thing they missed or got wrong
      - "better_questions": array of strings — each entry one question they should have asked themselves
      - "next_step": string — one specific thing to study
      - "improved_code": string — #{improved_code_instruction(section)}

      Each array entry must be ONE self-contained idea in one or two sentences. Never pack
      several points into one entry, and never number points inside an entry ("1) ... 2) ...")
      — separate ideas belong in separate entries. Use an empty array when there is nothing to
      say for that field.
    PROMPT
  end

  def improved_code_instruction(section)
    ExerciseSection.find(section)&.improved_code? == false ?
      "must be an empty string for this section" :
      "corrected/improved code for this section"
  end

  def section_grading_note(exercise, daily_response, section)
    case section
    when "architecture"
      "Evaluate the architecture answer on the DEPTH of its reasoning, not a single correct answer:\n" \
      "- Did they weigh real tradeoffs between the options?\n" \
      "- Did they address the stated constraints (scale, team, reliability, tech debt)?\n" \
      "- Did they consider alternatives rather than asserting one option?"
    when "security_review"
      "Evaluate on whether they correctly identified a real, exploitable vulnerability and whether their " \
      "proposed mitigation is sound — not against one single expected answer. Give partial credit in " \
      "\"missed\" for identifying the vulnerability without a complete mitigation, or vice versa."
    when "parsons_problem"
      parsons_review_block(exercise.parsons_problem, daily_response.answers["parsons_problem"])
    when "pattern"
      "For \"pattern\", improved_code must show the refactored structure that addresses what they missed — " \
      "the classes, methods, and boundaries the pattern calls for — not a one-line tweak. A pattern fix is " \
      "structural; show enough of the shape to make the structure obvious."
    else
      ""
    end
  end

  def build_concept_reference_prompt(concept, config)
    label = config[:label]
    code_example_desc =
      if config[:concepts] == ARCHITECTURE_CONCEPTS
        "illustrative pseudocode or a short language-agnostic snippet, ~15 lines"
      else
        "annotated #{label} code, ~15 lines"
      end

    <<~PROMPT
      Write a durable reference for the #{config[:coach]} concept: "#{concept}".
      This is a stable explanation an engineer returns to across repeat exposure —
      not tied to any single problem. Be precise and senior-level.

      Return JSON matching this schema exactly:
      {
        "tagline":      "string — bold one-liner",
        "explanation":  "string — 2-3 sentences",
        "code_example": "string — #{code_example_desc}",
        "senior_lens":  "string — when to reach for it / tradeoffs"
      }
    PROMPT
  end

  # Both callers persist the result into a jsonb column and then index into it
  # by key, so a non-Hash payload has to fail here rather than downstream: an
  # array saved to ai_review is still truthy, which flips DailyResponse#reviewed?
  # and leaves the user an empty review they can't regenerate.
  def parse_json_object(text, subject:)
    parsed = parse_json_response(text)
    return parsed if parsed.is_a?(Hash)

    raise InvalidResponseError, "Provider returned #{parsed.class} instead of a JSON object for the #{subject}"
  end

  def parse_json_response(text)
    # Strip any accidental markdown fences
    clean = text.to_s.gsub(/\A```(?:json)?\n?/, "").gsub(/\n?```\z/, "").strip
    JSON.parse(clean)
  rescue JSON::ParserError => e
    log_raw_snippet("Invalid JSON from provider", text)
    raise InvalidResponseError, "Provider returned invalid JSON: #{e.message}"
  end

  # Extracts a provider's own explanation for a failed HTTP response, when
  # one is available, so users see actionable detail (e.g. "credit balance
  # too low") instead of a bare status code. Falls back to `fallback`
  # whenever the body isn't parseable JSON or lacks the expected shape (5xx
  # HTML error pages, empty bodies, unrecognized formats). Both Anthropic
  # and Gemini nest their error detail the same way:
  # {"error": {"type": "...", "message": "..."}}.
  def extract_provider_message(body, fallback:)
    parsed  = JSON.parse(body.to_s)
    message = parsed.is_a?(Hash) ? parsed.dig("error", "message") : nil
    message.presence || fallback
  rescue JSON::ParserError
    fallback
  end

  # Logs a truncated snippet of raw provider output server-side instead of
  # embedding it in an exception message — exception messages surface in
  # flash alerts and error trackers, where large/undesired content would
  # leak to users and bloat logs.
  def log_raw_snippet(label, content)
    text = content.to_s
    # .scrub guards against byteslice cutting a multi-byte UTF-8 character in
    # half at the truncation boundary, which would otherwise leave an invalid
    # byte sequence in the log line.
    snippet = text.byteslice(0, RAW_SNIPPET_LIMIT).scrub
    snippet += "... (truncated, #{text.bytesize} bytes total)" if text.bytesize > RAW_SNIPPET_LIMIT
    Rails.logger.error("#{label}: #{snippet}")
  end

  # A provider occasionally invents tags; keep the vocabulary closed so
  # aggregation over concept history stays clean. Off-list concepts are
  # still recorded (via SuggestedConcept) as a background signal for future
  # vocabulary growth — this never changes what's persisted to the response
  # itself, which still gets "other".
  def normalize_concepts(problem_set, language = "ruby_rails")
    problem_set.each do |section_key, section|
      next unless section.is_a?(Hash) && section.key?("concept")
      bucket, vocab = concept_vocabulary_for(section_key, language)
      original = section["concept"]
      unless vocab.include?(original)
        section["concept"] = "other"
        record_suggested_concept(bucket, original)
      end
    end
    problem_set
  end

  # Parsons correctness is decided in Ruby, never by the model — whatever rating it returned
  # is discarded and replaced. Skipped when the stored section has no blocks, since there is
  # nothing to grade against and the grader would report a spurious perfect score. Operates on
  # a single un-nested section hash (the shape #review_sections works with), unlike the old
  # whole-review override_parsons_rating! this replaces.
  def override_parsons_section_rating!(review, exercise, daily_response)
    parsons = exercise.parsons_problem
    return review unless parsons.is_a?(Hash)

    blocks = Array(parsons["blocks"])
    return review if blocks.empty?

    submitted = ExerciseSection::ParsonsProblem.parse_order(daily_response.answers["parsons_problem"])
    review["rating"] = ExerciseSection::ParsonsProblem.grade(submitted, blocks.size)[:rating]
    review
  end

  # The provider returns "blocks" already in correct order, so the scramble is
  # rolled once here and persisted — refreshes and the history view then show
  # the same arrangement. Never the identity permutation, which would ship an
  # already-solved problem.
  def shuffle_parsons_blocks!(problem_set)
    parsons = problem_set["parsons_problem"]
    return problem_set unless parsons.is_a?(Hash) && parsons["blocks"].is_a?(Array)

    identity = (0...parsons["blocks"].size).to_a
    order    = identity.shuffle
    order    = identity.shuffle while order == identity && identity.size > 1
    parsons["display_order"] = order
    problem_set
  end

  # The (suggestion-bucket, vocabulary) a section's concept is validated against.
  # The section kind names which vocabulary applies (see ExerciseSection); the
  # constants themselves stay here. An unrecognized section key — a provider can
  # invent one — falls back to the language's full vocabulary, as it always has.
  private def concept_vocabulary_for(section_key, language)
    vocabulary =
      case ExerciseSection.find(section_key)&.vocabulary_key
      when :architecture      then ARCHITECTURE_CONCEPTS
      when :security_concepts then config_for(language)[:security_concepts]
      else                         config_for(language)[:concepts]
      end

    [ ConceptBucket.for(section_key, language), vocabulary ]
  end

  # Never allowed to break generation — a bug here is a lost analytics
  # signal, not a reason to fail the request.
  def record_suggested_concept(language, name)
    SuggestedConcept.record!(language: language, name: name)
  rescue => e
    Rails.logger.warn("SuggestedConcept recording failed: #{e.message}")
  end

  def log_usage(user, result, purpose:)
    ApiUsage.create!(
      user:       user,
      tokens_in:  result[:input_tokens].to_i,
      tokens_out: result[:output_tokens].to_i,
      purpose:    purpose,
      date:       Date.current
    )
  rescue => e
    Rails.logger.warn("ApiUsage log failed: #{e.message}")
  end

  # Every provider entry point funnels through here so usage is recorded on
  # exactly one path. A truncated response is still a billed response — and
  # the most expensive kind, since it burned the whole output budget — so the
  # usage row has to be written before the failure propagates, or cost
  # tracking under-counts precisely the calls that cost the most.
  #
  # Providers report truncation as data (`truncated:`) rather than raising it
  # themselves: recognizing a stop reason is provider-specific, but deciding
  # that it's fatal is shared policy, and belongs with the rest of the
  # response handling here.
  def call_and_log(user, purpose:, system:, prompt:, cache_system: false)
    result = call(system: system, prompt: prompt, cache_system: cache_system)
    log_usage(user, result, purpose: purpose)

    if result[:truncated]
      raise TruncatedResponseError,
            "Provider stopped generating at its output token limit (#{result[:output_tokens].to_i} tokens)"
    end

    result
  end
end
