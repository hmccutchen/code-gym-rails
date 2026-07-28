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

  # Fixed concept vocabularies, one per generation language. Embedded in the
  # generation prompt; anything a provider returns outside the active list is
  # normalized to "other" so per-user concept history stays aggregatable.
  # Kept closed rather than AI-extensible so history stays clean.
  RAILS_CONCEPTS = %w[
    n_plus_one transaction_safety memoization service_objects scope_chaining
    idempotency authorization background_jobs caching validations
    callbacks_vs_service query_objects policy_objects indexing concurrency
    error_handling
  ].freeze

  JS_CONCEPTS = %w[
    callback_hell promise_chaining closures prototype_chain event_loop_blocking
    this_binding array_mutation_pitfalls debouncing_throttling closures_in_loops
    memory_leaks_listeners hooks_dependencies component_re_renders state_lifting
    controlled_vs_uncontrolled
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

  # Single source of truth per concrete generation language ("mixed" is a
  # user-level meta-preference that always resolves to one of these before it
  # reaches AiService — see User#language_for_today). Adding a language means
  # adding one entry here, not hunting down every ternary in this file.
  LANGUAGE_CONFIG = {
    "ruby_rails" => {
      label:    "Ruby/Rails",
      concepts: RAILS_CONCEPTS,
      coach:    "Rails",
      focus:    "real Rails patterns: N+1 queries, idempotency, background jobs, authorization, service objects, query objects, policy objects."
    },
    "javascript" => {
      label:    "JavaScript/React",
      concepts: JS_CONCEPTS,
      coach:    "JavaScript/React",
      focus:    "real JavaScript/React patterns: closures, async/event-loop pitfalls, prototypal inheritance, `this` binding, and hooks/re-renders."
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
  def self.for(user)
    case user.provider
    when "anthropic" then ClaudeService.new(user.api_key)
    when "gemini"    then GeminiService.new(user.api_key)
    else
      raise Error, "User #{user.id} has no recognized AI provider configured"
    end
  end

  # ── Generate a personalized daily exercise set ────────────────────────────
  # Concept selection happens HERE rather than inside build_exercise_prompt so the
  # caller can compare what was offered against what the model actually used — the
  # prompt builder is private and returns only a string, so it cannot report that.
  def generate_exercise(user, language: user.language_for_today)
    third         = roll_third_section
    reinforcement = user.concepts_needing_reinforcement
    slots         = [ 3 - reinforcement.size, 0 ].max
    due_checks    = retention_checks_for(user, language, third: third, slots: slots)

    result = call(system: build_system_prompt(language),
                  prompt: build_exercise_prompt(user, language, third: third,
                                                reinforcement: reinforcement, due_checks: due_checks))

    log_usage(user, result, purpose: "generate_exercise")
    problem_set = normalize_concepts(parse_json_object(result[:text], subject: "problem set"), language)
    log_retention(user, language, due_checks, problem_set)
    problem_set
  end

  # ── Review a submitted response inline ───────────────────────────────────
  def review_response(user, exercise, daily_response)
    coach = config_for(exercise.language)[:coach]

    result = call(
      system: "You are a senior #{coach} engineer giving direct, specific feedback on a junior/mid engineer's Code Gym answers. Be honest and constructive. Return JSON.",
      prompt: build_review_prompt(exercise, daily_response)
    )

    log_usage(user, result, purpose: "review_response")
    parse_json_object(result[:text], subject: "review")
  end

  # ── Generate the one-time cached reference for a single concept ───────────
  def generate_concept_reference(user, concept, language)
    config = config_for(language)

    result = call(
      system: "You are a senior #{config[:coach]} engineer writing a concise, durable reference for one concept. Return ONLY valid JSON.",
      prompt: build_concept_reference_prompt(concept, config)
    )

    log_usage(user, result, purpose: "generate_concept_reference")
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

    result = call(
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

    log_usage(user, result, purpose: "explain_differently")
    result[:text].to_s.strip
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

    result = call(
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

    log_usage(user, result, purpose: "review_follow_up")
    result[:text].to_s.strip
  end

  private

  # Looks up the fixed per-language config, failing loudly on anything
  # outside RAILS_CONCEPTS/JS_CONCEPTS's languages (e.g. "mixed", or a typo)
  # instead of silently degrading to Ruby/Rails behavior.
  def config_for(language)
    LANGUAGE_CONFIG.fetch(language) do
      raise Error, "Unsupported generation language: #{language.inspect}"
    end
  end

  # Which third section this set gets: architecture-reasoning 75% of the time,
  # a traditional coding challenge 25%. Extracted so tests can stub it — never
  # assert on real randomness. The chosen kind is not tracked separately; the
  # persisted third key (problem_set["architecture"] vs ["challenge"]) is the record.
  def roll_third_section
    rand < 0.75 ? :architecture : :challenge
  end

  # Due retention checks for the buckets this day can actually host. Architecture
  # concepts have no home outside the architecture third, and a language concept
  # must match the day's resolved generation language — otherwise a mixed-language
  # user gets a Rails concept on a JavaScript day.
  def retention_checks_for(user, language, third:, slots:)
    return [] if slots.zero?

    buckets = [ language ]
    buckets << "architecture" if third == :architecture

    buckets.flat_map { |bucket| user.concepts_due_for_retention_check(bucket: bucket, limit: slots).to_a }
           .sort_by(&:next_retention_check_on)
           .first(slots)
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
  def call(system:, prompt:)
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

    third_section =
      if third == :architecture
        <<~ARCH.chomp
          "architecture": {
              "title":     "string — short name for the decision",
              "scenario":  "string — 2-3 sentences, ~50 words max. Exactly 2-3 concrete constraints total, no more",
              "question":  "string — ONE sentence asking for a decision + justification",
              "options":   ["string — a viable approach", "string — another viable approach", "string — an optional third approach (omit for 2)"],
              "teaching_note": "string — 1-2 sentence hint toward HOW to reason, never the answer",
              "concept": "string — exactly one concept from the architecture vocabulary",
              "reference": {
                "tagline":     "string — bold one-liner",
                "explanation": "string — 2-3 sentences",
                "tradeoffs":   ["string — a tradeoff", "string — a tradeoff", "string — a tradeoff"],
                "senior_lens": "string — how a senior frames the decision"
              }
            }
        ARCH
      else
        <<~CH.chomp
          "challenge": {
              "title":        "string",
              "question":     "string — what to implement",
              "scenario": "string — the concrete business-domain framing, e.g. 'inventory restocking service'",
              "starter_code": "string — optional skeleton (empty string if none)",
              "teaching_note": "string — 1-2 sentence hint toward the key insight, never the answer",
              "concept": "string — exactly one concept from the provided vocabulary"
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
          "scenario": "string — the concrete business-domain framing, e.g. 'inventory restocking service'"
        },
        "pattern": {
          "title":    "string — pattern name",
          "why":      "string — one sentence on why the pattern exists",
          "question": "string — conceptual question to answer",
          "scenario": "string — the concrete business-domain framing, e.g. 'inventory restocking service'",
          "teaching_note": "string — 1-2 sentence hint toward the key insight, never the answer",
          "concept": "string — exactly one concept from the provided vocabulary"
        },
        #{third_section}
      }
    SCHEMA
  end

  def build_exercise_prompt(user, language = "ruby_rails", third: :challenge, reinforcement: nil, due_checks: [])
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

          Retention checks due today: #{due_checks.map(&:concept).join(', ')}
          - These are concepts the engineer previously MASTERED. Work each one into a section above, alongside the reinforcement concepts.
          - Use a completely FRESH scenario for these — a new business domain, new class and method names, a new narrative. Never reuse any framing listed above. This tests whether they retained the idea, not whether they recognize a memorized example.
          - Pitch these at FULL difficulty. Do NOT ease them, add scaffolding, or write a more direct teaching_note the way you would for a `(reduced)` concept — the engineer is not struggling with these, and making them easier defeats the point of checking.
        RET
      else
        ""
      end

    config      = config_for(language)
    label       = config[:label]
    focus       = user.focus_areas.any? ? user.focus_areas.join(", ") : "general #{label} patterns"
    concepts    = config[:concepts]

    third_guidance =
      if third == :architecture
        <<~ARCH.chomp
          - The third section is an ARCHITECTURE decision, not a coding task. Present 2-3 viable options and ask for a decision plus justification. Its reference must center on tradeoffs (plural).
          - Keep the architecture scenario SHORT: 2-3 sentences, ~50 words maximum, and exactly 2-3 concrete constraints total. Usually the observable symptom plus one hard technical constraint is enough — pick only the constraints the decision actually turns on, and leave the rest out. Do NOT stack scale figures, team size, infrastructure detail, budget, and timeline into one scenario.
          - Short does not mean vague: name real numbers and real systems for the 2-3 constraints you do include. Fewer constraints, not fuzzier ones.
          - The architecture question itself is one sentence — do not restate the scenario in it.
          - Choose the code_review and pattern concepts from this vocabulary, exactly one each: #{concepts.join(", ")}
          - Choose the architecture section's concept from this SEPARATE vocabulary, exactly one: #{ARCHITECTURE_CONCEPTS.join(", ")}
        ARCH
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
      - The code_review snippet must be realistic #{label} code — not toy examples.
      - Rotate between topics across sessions — avoid the same pattern two days in a row.
      - Vary the concrete business-domain scenario and code structure across sessions, not just the concept — do not reuse the class/method names or narrative framing shown in the "framings:" notes above.
      - Each teaching_note must point toward how to think about the problem or the right question to ask — one or two sentences, never the full answer.
      #{third_guidance}
      - Reduced-tier concepts: for any concept marked `(reduced)`, keep the SAME concept and vocabulary — never silently swap in a different, easier concept. Ease the difficulty only: simpler framing, a smaller scenario, more scaffolding/starter code, and a teaching_note that guides more directly toward the key insight (it may name the technique, but not the full answer).
      - Mastery loop: reintroduce every concept listed as "needing reinforcement right now" above (both standard and reduced tiers) with a fresh code example and framing — never a repeat snippet. A concept exits reinforcement only on full mastery: the user's self-rating for that section was "right level"/"too easy" AND the AI rated it "solid"/"strong". Short of that, steady improvement (a better AI rating than last time) still counts as progress — keep reinforcing, and let the tier annotation tell you how hard to pitch it.
      #{retention_block}
      - Concepts most recently rated "too easy" must not repeat within the same week.
      - Concepts most recently rated "right level" have no special weighting.

      Return JSON matching this schema exactly:
      #{exercise_schema_for(language, third: third)}
    PROMPT
  end

  def build_review_prompt(exercise, daily_response)
    answers = daily_response.answers
    arch    = exercise.architecture

    third_block =
      if arch
        <<~ARCH.chomp
          Architecture decision (#{arch["title"]}): #{arch["question"]}
          Scenario/constraints: #{arch["scenario"]}
          Their answer: #{answers["architecture"].presence || "(skipped)"}

          Evaluate the architecture answer on the DEPTH of its reasoning, not a single correct answer:
          - Did they weigh real tradeoffs between the options?
          - Did they address the stated constraints (scale, team, reliability, tech debt)?
          - Did they consider alternatives rather than asserting one option?
          For this section "improved_code" must be an empty string.
        ARCH
      else
        <<~CH.chomp
          Coding Challenge: #{exercise.challenge["question"]}
          Their answer: #{answers["challenge"].presence || "(skipped)"}
        CH
      end

    third_key = arch ? "architecture" : "challenge"

    <<~PROMPT
      Review these Code Gym answers. For each section, return a JSON object with:
      - "rating": "beginner" | "developing" | "solid" | "strong"
      - "correct": array of strings — each entry one distinct thing they got right
      - "missed": array of strings — each entry one distinct thing they missed or got wrong
      - "better_questions": array of strings — each entry one question they should have asked themselves
      - "next_step": string — one specific thing to study
      - "improved_code": string — corrected/improved code for #{third_key == "architecture" ? "code_review and pattern" : "code_review, pattern, and challenge"}#{third_key == "architecture" ? " (empty string for architecture)" : ""}

      Each array entry must be ONE self-contained idea in one or two sentences.
      Never pack several points into one entry, and never number points inside an
      entry ("1) ... 2) ...") — separate ideas belong in separate entries. Use an
      empty array when there is nothing to say for that field.

      For "pattern", improved_code must show the refactored structure that addresses
      what they missed — the classes, methods, and boundaries the pattern calls for —
      not a one-line tweak. A pattern fix is structural; show enough of the shape to
      make the structure obvious.

      Exercise:
      Code Review question: #{exercise.code_review["question"]}
      Code snippet: #{exercise.code_review["snippet"]}
      Their answer: #{answers["code_review"].presence || "(skipped)"}

      Pattern question (#{exercise.pattern["title"]}): #{exercise.pattern["question"]}
      Their answer: #{answers["pattern"].presence || "(skipped)"}

      #{third_block}

      Return JSON with keys: "code_review", "pattern", "#{third_key}" — each matching the schema above.
    PROMPT
  end

  # Mirrors the pattern-section `reference` shape so both render identically.
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

  # The (suggestion-bucket, vocabulary) a section's concept is validated against.
  # The architecture section is language-independent — always ARCHITECTURE_CONCEPTS,
  # bucketed under "architecture"; every other section follows the generation language.
  private def concept_vocabulary_for(section_key, language)
    if section_key == "architecture"
      [ "architecture", ARCHITECTURE_CONCEPTS ]
    else
      [ language, config_for(language)[:concepts] ]
    end
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
end
