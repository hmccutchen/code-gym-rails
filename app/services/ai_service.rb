require "json"

class AiService
  class Error < StandardError; end

  # Bad/revoked API key (HTTP 401/403) — user-actionable: they need to fix
  # their key in Settings. Never worth retrying.
  class AuthenticationError < Error; end

  # Transient rate limiting (HTTP 429) that survived Faraday's own retries.
  # User-actionable in the sense of "try again shortly", but not a bug.
  class RateLimitError < Error; end

  # The read budget ran out before the provider answered. Separated from a
  # generic Error so callers can report it in the user's terms: the raw
  # Faraday message ("Net::ReadTimeout with #<TCPSocket:(closed)>") is a
  # socket-level detail that used to reach the dashboard verbatim.
  class TimeoutError < Error; end

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

  # Every provider call is made from a request thread (#review and the
  # on-demand generation path both block on it), so an unbounded call ties up
  # a Puma thread indefinitely and outlives ResponsesController's review claim,
  # letting a second review start while the first is still in flight. Faraday
  # sets no timeout by default. The read budget is generous because a full
  # section review legitimately takes tens of seconds; the ceiling that matters
  # is (attempts × (open + read)) + retry backoff staying under
  # ResponsesController::REVIEW_CLAIM_STALE_AFTER, which ai_service_spec
  # asserts so the two cannot drift apart.
  OPEN_TIMEOUT = 10
  READ_TIMEOUT = 45

  # Generation asks for the single largest response we ever request — one
  # non-streaming call carrying every section, including the full reference
  # blocks — from a model that thinks before it answers, so the socket stays
  # silent until the whole thing is built. READ_TIMEOUT was sized for a
  # per-section review, and imposing it here made generation fail on
  # Net::ReadTimeout once ClaudeService::MAX_TOKENS grew.
  #
  # Two budgets, because generation runs from two places with different costs
  # for waiting:
  #   - GENERATION_READ_TIMEOUT: GenerateDailyExercisesJob, the morning batch
  #     and every on-demand dashboard trigger. Runs on the worker, holds no
  #     Puma thread and no review claim, and nobody is watching a spinner, so
  #     it can wait as long as the provider needs.
  #   - SYNC_GENERATION_READ_TIMEOUT: currently uncalled. It sized the read
  #     budget for a generation that blocks a Puma thread with a user waiting
  #     on the response — enough room to finish and no more. Its only caller
  #     was DailyExercisesController#regenerate, which now claims the row and
  #     enqueues RegenerateExerciseJob instead. Retained so any future
  #     synchronous caller inherits a bound rather than GENERATION_READ_TIMEOUT.
  GENERATION_READ_TIMEOUT      = 300
  SYNC_GENERATION_READ_TIMEOUT = 90

  # Passed to faraday-retry as `retry_if`. A read timeout on a generation is
  # taken as final: the provider has almost certainly finished, and billed, the
  # work we stopped waiting for, so retrying buys a duplicate charge for the
  # entire problem set rather than a better outcome. Short calls keep retrying,
  # and this never suppresses a retry_statuses retry (429/5xx arrive as
  # Faraday::RetriableResponse, not a timeout).
  RETRY_TIMEOUT_GUARD = lambda do |env, exception|
    return true unless exception.is_a?(Faraday::TimeoutError)

    !env.request.context.to_h[:long_running]
  end

  # Cost and length control for #duck_response. 250 tokens fits both shapes the
  # system prompt asks for: a 1-3 sentence guiding question, and a plain-language
  # explanation with a concrete analogy — the latter does not fit in the 150 this
  # started at. It remains a budget, not an enforcement mechanism: a short fix
  # fits in 250 tokens too, so DUCK_SYSTEM_PROMPT's rules are still the only
  # thing actually asking the model not to give answers.
  #
  # Deliberately one ceiling for every duck reply rather than a higher one for
  # explain-requests. The server cannot know which kind a message is until the
  # model has answered it, so branching would mean trusting a client-declared
  # flag that any client could set on every request — a per-type ceiling that
  # does not hold is worse than one honest number.
  # Deliberately distinct from ClaudeService::MAX_TOKENS, which is sized for
  # full review generation.
  DUCK_RESPONSE_MAX_TOKENS = 250

  # The message the "Explain this simply" button sends on the user's behalf.
  # Server-owned so its wording lives beside the prompt it is tuned against: it
  # names the exercise rather than the answer, so it reads as a kind-1 request
  # under DUCK_SYSTEM_PROMPT without the prompt having to recognize it
  # specially. It reaches the endpoint as an ordinary message and counts
  # against the same turn cap as one.
  DUCK_EXPLAIN_REQUEST = "Explain what this exercise is asking, in plain language."

  DUCK_SYSTEM_PROMPT = <<~PROMPT.chomp
    You are a Socratic thinking partner helping an engineer work through a
    problem they have NOT yet submitted or been graded on.

    Every message they send is one of two kinds. Decide which before replying.

    1. UNDERSTANDING THE PROBLEM — they are asking what the exercise means, what
       a term or a piece of the snippet does, or for a plainer restatement of the
       question. Examples: "what is this even asking?", "what does memoization
       mean?", "explain this scenario simply", "what does this line do?"
       Answer these DIRECTLY and simply: plain words, one concrete everyday
       analogy if it helps, no jargon. Describe only what is already on their
       screen — the situation as written, the vocabulary, the shape of the
       question. Explaining what a problem IS is always allowed.

    2. SOLVING THE PROBLEM — they are asking for the fix, the answer, corrected
       code, which option to pick, or what is wrong with the snippet. Examples:
       "what's the bug?", "how do I fix this?", "which option is right?", "just
       tell me the answer", "is my approach correct?"
       Never comply. Never state the correct answer, the specific fix, or write
       corrected or complete code — not even as an illustrative example. Respond
       with a single guiding question that helps them find it themselves.

    When a message mixes both ("what does this method do, and what's wrong with
    it?"), explain the first part and answer the second with a guiding question.
    When you genuinely cannot tell which kind it is, treat it as kind 2.

    Keep it short: 1-3 sentences for a guiding question, up to 4 for an
    explanation. No preamble.
  PROMPT

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

  # Data-modeling concepts, folded into BOTH language vocabularies rather than
  # given a bucket of their own. A bucket is not possible here: ConceptBucket
  # dispatches on section key, and this content mode's key is still
  # "code_review". Per-language mastery tracking is the accepted cost, and is
  # arguably correct — indexing and migration-safety concerns differ enough
  # between an ActiveRecord/Postgres context and a Prisma one to track apart.
  #
  # One shared list rather than two, unlike RAILS_SECURITY_CONCEPTS /
  # JS_SECURITY_CONCEPTS, whose contents genuinely differ. These do not: the
  # Prisma artifact is relational, so every entry means the same thing in both
  # languages. Two identical lists would only be somewhere to drift.
  #
  # `unsafe_migration` is operational rather than structural, and belongs
  # anyway: the artifact under review IS a migration, so its safety is in
  # frame by construction. It passes the same depth filter as the rest — a
  # lock is the easy version, backfill-then-constrain across deploys the
  # harder one, knowing when the safe path isn't worth its complexity the
  # hardest.
  DATA_MODELING_CONCEPTS = %w[
    missing_index wrong_cardinality missing_constraint
    denormalization_tradeoffs unsafe_migration
  ].freeze

  # Reasoning skills rather than technical topics — how to approach a problem,
  # not a thing to know about it. They sit in both language vocabularies rather
  # than a bucket of their own because ConceptBucket dispatches on section key,
  # never on concept: a bucket would require a section kind, and this is
  # deliberately not one. The cost is per-language mastery. The gain is that
  # these are absent from LANGUAGE_AGNOSTIC_VOCABULARIES, so their concept
  # reference shows real Rails or JavaScript code — the better illustration for
  # a concept about reading code than pseudocode would be.
  META_SKILL_CONCEPTS = %w[
    reading_for_intent spotting_unstated_assumptions separating_symptom_from_cause
  ].freeze

  # Named smells rather than the remedies the language vocabularies already
  # carry (service_objects, query_objects, state_lifting name the cure). Shared
  # across both languages because each means the same thing in a Rails class
  # and a React component.
  CODE_SMELL_CONCEPTS = %w[
    god_object primitive_obsession shotgun_surgery feature_envy
  ].freeze

  # The rule underneath the smell: the code smells name a shape to recognize
  # and the language vocabularies name a remedy, but nothing named the design
  # principle either one appeals to. Evaluative rather than situational — "does
  # this violate open/closed?" is askable of almost any snippet, which is what
  # makes three principles a better fit here than the GoF catalog, whose 22
  # patterns would nearly double both vocabularies and starve the mastery loop.
  #
  # Five candidates were cut rather than shipped as twins. single_responsibility
  # is god_object named from the rule side and generates the same section;
  # program_to_interface is dependency_inversion with a less findable violation;
  # encapsulate_what_varies is open_closed with a blurrier one. Neither
  # liskov_substitution nor interface_segregation survives the relevance filter
  # in duck-typed Ruby and hooks-based React, and completing SOLID is not a
  # reason to carry a concept this app's sections cannot host well.
  #
  # Shared across both languages because each means the same thing in a Rails
  # class and a React component, and deliberately outside
  # LANGUAGE_AGNOSTIC_VOCABULARIES so a concept reference shows real code.
  OO_DESIGN_CONCEPTS = %w[
    open_closed dependency_inversion composition_over_inheritance
  ].freeze

  # The cost of an interface rather than a defect in what it computes: the code
  # smells name a shape, the design principles name a rule, and the language
  # vocabularies name a remedy, but nothing named what a module's interface
  # charges every caller who uses it. Diagnostic rather than situational —
  # "does this module hide more than it asks you to learn?" is askable of
  # almost any snippet, which is the same filter that made the design
  # principles a better fit here than a pattern catalog.
  #
  # Two candidates were cut rather than shipped as twins. information_leakage
  # is shotgun_surgery named from the cause side and generates the same
  # section, and coupling_cohesion already carries the architecture-level
  # version; special_general_mixture's findable violation is the same
  # conditional an open_closed section shows.
  #
  # Shared across both languages because each means the same thing in a Rails
  # class and a React component, and deliberately outside
  # LANGUAGE_AGNOSTIC_VOCABULARIES so a concept reference shows real code.
  MODULE_DESIGN_CONCEPTS = %w[
    shallow_module pass_through_method temporal_decomposition
  ].freeze

  # The architecture-level causes of complexity, kept as their own constant
  # because ANTI_SHAPE_CONCEPTS below has to name them and ARCHITECTURE_CONCEPTS
  # is defined further down.
  COMPLEXITY_CAUSE_CONCEPTS = %w[
    cognitive_load unknown_unknowns
  ].freeze

  # The groups that name something to find rather than something to choose.
  # Every lens written for a remedy is wrong for these — see the senior_lens
  # framing in #build_concept_reference_prompt, whose output is generated once
  # and cached forever, so a wrong framing never self-corrects. Membership
  # rather than "every group with a guidance method": the design principles
  # have one too, and a principle IS something to reach for.
  ANTI_SHAPE_CONCEPTS = (CODE_SMELL_CONCEPTS + MODULE_DESIGN_CONCEPTS + COMPLEXITY_CAUSE_CONCEPTS).freeze

  RAILS_CONCEPTS = (%w[
    n_plus_one transaction_safety memoization service_objects scope_chaining
    idempotency authorization background_jobs caching validations
    callbacks_vs_service query_objects policy_objects indexing concurrency
    error_handling mass_assignment_protection sql_injection_prevention
    over_mocking testing_implementation_not_behavior
  ] + DATA_MODELING_CONCEPTS + META_SKILL_CONCEPTS + CODE_SMELL_CONCEPTS + OO_DESIGN_CONCEPTS +
    MODULE_DESIGN_CONCEPTS).freeze

  JS_CONCEPTS = (%w[
    callback_hell promise_chaining closures prototype_chain event_loop_blocking
    this_binding array_mutation_pitfalls debouncing_throttling closures_in_loops
    memory_leaks_listeners hooks_dependencies component_re_renders state_lifting
    controlled_vs_uncontrolled xss_prevention insecure_client_storage
    generics type_guards_narrowing union_intersection_types mapped_conditional_types
    over_mocking testing_implementation_not_behavior
  ] + DATA_MODELING_CONCEPTS + META_SKILL_CONCEPTS + CODE_SMELL_CONCEPTS + OO_DESIGN_CONCEPTS +
    MODULE_DESIGN_CONCEPTS).freeze

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
  #
  # COMPLEXITY_CAUSE_CONCEPTS are causes of complexity rather than decisions,
  # and they sit here rather than in the language vocabularies
  # because what they cost is only visible across a whole design.
  # change_amplification was cut with them: it is coupling_cohesion's symptom
  # at this altitude, and shotgun_surgery already carries the code-level
  # version in both language vocabularies.
  ARCHITECTURE_CONCEPTS = (%w[
    sync_vs_async service_boundaries coupling_cohesion data_consistency_tradeoffs
    caching_strategy build_vs_buy scaling_bottlenecks failure_mode_design
    api_versioning event_driven_vs_request_response data_ownership
    idempotency_at_scale observability_tradeoffs
  ] + COMPLEXITY_CAUSE_CONCEPTS).freeze

  # Vocabulary for the plan_review fourth-slot kind. Entirely disjoint from
  # RAILS_CONCEPTS/JS_CONCEPTS/ARCHITECTURE_CONCEPTS — a plan_review concept
  # can never appear in code_review/pattern/third, and vice versa. All four
  # pass the same depth filter used to trim the security vocabulary: each has
  # room to be approached multiple ways and to get harder or easier.
  PLAN_REVIEW_CONCEPTS = %w[
    unjustified_constant contradicts_existing_pattern scope_creep silent_behavior_change
  ].freeze

  # Vocabulary for the ambiguity_hunt fourth-slot kind. Same disjointness rule
  # as PLAN_REVIEW_CONCEPTS.
  AMBIGUITY_HUNT_CONCEPTS = %w[
    undefined_scope_boundary unspecified_edge_cases missing_success_criteria
    unstated_data_implications undefined_permissions_model
  ].freeze

  # Curated, real, job-adjacent scenario flavors for the "scenario" field's
  # business-domain framing — prompt-level grounding only, to keep generated
  # scenarios feeling like real engineering work rather than generic SaaS
  # examples. Never concept-tagged, never fed into ProblemSetIngest.vocabulary_for or
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
      schema_artifact:   "a Rails migration",
      focus:             "real Rails patterns: N+1 queries, idempotency, background jobs, authorization, service objects, query objects, policy objects."
    },
    "javascript" => {
      label:             "JavaScript/React",
      concepts:          JS_CONCEPTS,
      security_concepts: JS_SECURITY_CONCEPTS,
      coach:             "JavaScript/React",
      test_framework:    "a Jest/Vitest-style",
      # Prisma schema change with its migration: unsafe_migration cannot be planted in a schema.prisma, which has no migration semantics.
      schema_artifact:   "a Prisma schema change, with the migration it generates",
      focus:             "real JavaScript/React patterns: closures, async/event-loop pitfalls, prototypal inheritance, `this` binding, and hooks/re-renders."
    },
    "architecture" => {
      label:    "language-agnostic",
      concepts: ARCHITECTURE_CONCEPTS,
      coach:    "software architecture",
      focus:    "system-design tradeoffs: service boundaries, consistency, failure modes, scale, coupling."
    },
    "plan_review" => {
      label:    "language-agnostic",
      concepts: PLAN_REVIEW_CONCEPTS,
      coach:    "engineering plan review",
      focus:    "spotting flaws in a written implementation plan before it's built: unjustified complexity, scope creep, and unflagged behavior changes."
    },
    "ambiguity_hunt" => {
      label:    "language-agnostic",
      concepts: AMBIGUITY_HUNT_CONCEPTS,
      coach:    "requirements analysis",
      focus:    "interrogating an underspecified feature request: missing scope boundaries, unhandled edge cases, and unstated success criteria."
    }
  }.freeze

  # Vocabularies with no code of their own to reference — a concept from any
  # of these has nothing language-specific to show, so their concept
  # reference asks for illustrative pseudocode instead of real source.
  LANGUAGE_AGNOSTIC_VOCABULARIES = [ ARCHITECTURE_CONCEPTS, PLAN_REVIEW_CONCEPTS, AMBIGUITY_HUNT_CONCEPTS ].freeze

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
  #
  # `blocking:` says a request thread is waiting on this call, which buys a
  # tighter read budget (see SYNC_GENERATION_READ_TIMEOUT). Callers state their
  # constraint; the timeout policy stays here.
  def generate_exercise(user, language: user.language_for_today, blocking: false)
    plan = DailyPlan.for(user, language: language)
    # Fetched once and threaded through to both the prompt and the
    # diagnostics log below — two separate calls to #recent_performance
    # would double the query and risk the logged "requested" history
    # silently diverging from what the prompt actually contained if
    # anything changed for this user during the provider call.
    history = user.recent_performance

    result = call_and_log(
      user, purpose: "generate_exercise",
      read_timeout: blocking ? SYNC_GENERATION_READ_TIMEOUT : GENERATION_READ_TIMEOUT,
      system: build_system_prompt(language),
      prompt: build_exercise_prompt(user, language, third: plan.third, pattern: plan.pattern,
                                    reinforcement: plan.reinforcement, due_checks: plan.due_checks,
                                    established: plan.established, history: history,
                                    fourth: plan.fourth, fourth_reinforcement: plan.fourth_reinforcement,
                                    fourth_due_checks: plan.fourth_due_checks, fourth_established: plan.fourth_established,
                                    code_review_mode: plan.code_review_mode)
    )

    ingested = ProblemSetIngest.call(
      parse_json_object(result[:text], subject: "problem set"),
      language: language,
      expected_keys: ExerciseSection.for_plan(third: plan.third, fourth: plan.fourth,
                                              pattern: plan.pattern).map(&:key)
    )
    problem_set = ingested.problem_set
    # After ingest, never during: ingest writes nothing and raises on an
    # unusable set, so a rejected response cannot have left a suggestion behind.
    record_suggested_concepts(ingested.suggested_concepts)
    log_retention(user, language, plan.due_checks, problem_set, plan.code_review_mode)
    if plan.fourth
      log_retention(user, DailyPlan::FOURTH_BUCKET_FOR.fetch(plan.fourth), plan.fourth_due_checks,
                    problem_set, plan.code_review_mode)
    end
    log_difficulty_diagnostics(user, language, plan, problem_set, history)
    problem_set
  end

  # ── Review a submitted response, one thread per still-missing section ────
  # Each thread gets its own service instance (and therefore its own Faraday
  # connection) — no shared mutable state crosses a thread boundary. A
  # section's failure is caught and tagged rather than raised, so one bad
  # section can never keep the other threads' results from being usable by
  # the caller.
  #
  # No pooled DB connection is held for the duration of a thread — only the
  # provider HTTP call happens here, and that can run up to READ_TIMEOUT
  # seconds. The one bit of real DB work (ApiUsage.create! inside #log_usage)
  # checks out a connection for itself, scoped narrowly in #call_and_log, so
  # a multi-section review never pins (section count) pooled connections for
  # the length of an HTTP round trip — with Puma's thread count and
  # database.yml's pool sized 1:1, that used to leave zero spare connections
  # for any concurrent request.
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

    thread_text = render_thread(thread, empty_message: "(no prior questions)")

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

  # ── Rubber-duck Socratic thinking-partner turn, pre-submission only ───────
  # Fully unpersisted: no `daily_response` argument, no draft-answer context,
  # no read of any stored state. `thread` is the client's own in-memory
  # conversation so far, sent back on every request — used only to build this
  # one prompt, never written anywhere.
  def duck_response(user, exercise, section:, message:, thread: [])
    context = duck_section_context(exercise, section)
    thread_text = render_thread(thread, empty_message: "(no prior messages)")

    result = call_and_log(
      user, purpose: "duck_thread", max_tokens: DUCK_RESPONSE_MAX_TOKENS,
      system: DUCK_SYSTEM_PROMPT,
      prompt: <<~PROMPT
        The exercise section:
        #{context}

        Conversation so far:
        #{thread_text}

        Their new message: #{message}

        Respond as their Socratic thinking partner, following your system instructions exactly.
      PROMPT
    )

    text_or_raise(result, subject: "duck response")
  end

  private

  # Shared by #answer_follow_up and #duck_response — both render a prior
  # `{ role:, content: }` conversation the same "You: .../Them: ..." way, so
  # a future fix to that rendering (e.g. how an unrecognized role is labeled)
  # only needs to land in one place.
  def render_thread(thread, empty_message:)
    return empty_message if thread.empty?

    thread.map { |turn| "#{turn[:role] == "assistant" ? "You" : "Them"}: #{turn[:content]}" }.join("\n")
  end

  # Plain-text summary of whichever fields a given section actually has
  # (code_review/pattern/challenge/architecture/security_review/
  # parsons_problem/plan_review/ambiguity_hunt all carry a different subset)
  # — enough context for a Socratic prompt without needing per-section-kind
  # branching. `planted_ambiguities` is deliberately excluded: it's the
  # answer key for ambiguity_hunt and must never reach a pre-submission prompt.
  def duck_section_context(exercise, section)
    data = exercise.problem_set.dig(section.to_s) || {}

    [
      ("Title: #{data["title"]}" if data["title"].present?),
      ("Scenario: #{data["scenario"]}" if data["scenario"].present?),
      ("Why it exists: #{data["why"]}" if data["why"].present?),
      ("Question: #{data["question"]}" if data["question"].present?),
      ("Options: #{Array(data["options"]).join(" / ")}" if data["options"].present?),
      ("Code snippet:\n#{data["snippet"]}" if data["snippet"].present?),
      ("Starter code:\n#{data["starter_code"]}" if data["starter_code"].present?),
      ("Plan excerpt:\n#{data["plan_excerpt"]}" if data["plan_excerpt"].present?),
      ("Feature request:\n#{data["request"]}" if data["request"].present?),
      duck_parsons_blocks(data)
    ].compact.join("\n")
  end

  # A Parsons question is only "arrange these blocks", so without the blocks
  # the model cannot say anything section-specific. But blocks are persisted
  # already-solved (see ProblemSetIngest#shuffle_parsons_blocks!), so their stored order IS
  # the answer the duck prompt forbids revealing. Positions are therefore only
  # ever quoted from a genuine persisted scramble; with no trustworthy
  # scramble to quote, the blocks go over unordered rather than in the stored
  # order, which would both leak the solution and misdescribe the screen.
  def duck_parsons_blocks(data)
    blocks = data["blocks"]
    return unless blocks.is_a?(Array) && blocks.any?

    order = scrambled_display_order(data["display_order"], blocks.size)
    # to_s before sorting: a provider can return non-strings, and Array#sort on
    # mixed types raises rather than degrading.
    return "Blocks (order withheld):\n#{blocks.map(&:to_s).sort.map { |b| "- #{b}" }.join("\n")}" unless order

    lines = order.map.with_index { |block_index, position| "#{position + 1}. #{blocks[block_index]}" }
    "Blocks, in the learner's current on-screen order (NOT the correct order):\n#{lines.join("\n")}"
  end

  # nil unless display_order is a complete permutation that actually differs
  # from the stored order. The identity permutation is rejected rather than
  # trusted: it means no scramble was ever persisted, and echoing it back
  # would present the solved arrangement as the learner's own.
  def scrambled_display_order(display_order, block_count)
    order = ExerciseSection::ParsonsProblem.normalize_order(Array(display_order), block_count)
    return if order.empty? || order == (0...block_count).to_a

    order
  end

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
  # concept can't go in code_review, guesses wrong, and ingest rewrites a
  # correctly-honored check into a false "miss".
  #
  # code_review's legal concepts now depend on the day's content mode as well:
  # a schema-review day hosts only data-modeling concepts, and every other day
  # hosts only the rest. pattern and the language-vocabulary thirds are
  # unscoped, which is what keeps a due data-modeling concept reachable on a
  # non-schema day.
  def annotate_retention_concept(cm, kinds, language, code_review_mode)
    hosts = kinds.filter_map do |kind|
      mode = code_review_mode if kind == ExerciseSection::CodeReview
      kind.key if can_host?(cm, kind.key, language, mode: mode)
    end

    # nil, not "concept ()": with every line derived, a day can present no
    # section able to carry this concept, and listing it anyway would tell the
    # model to "work it into one of those" over an empty set. The caller drops
    # it from the prompt instead. The old unconditional `pattern` line made
    # this unreachable; deriving it is what put the case back on the table.
    return nil if hosts.empty?

    "#{cm.concept} (#{hosts.to_sentence(two_words_connector: ' or ', last_word_connector: ', or ')})"
  end

  # Every slot answered by the same authority that decides what the generation
  # prompt may offer that section, so an annotation can never name a host whose
  # own vocabulary line in the same prompt withholds the concept.
  #
  # All three derive, deliberately. Two of them used to be restated by hand —
  # an unconditional `pattern` and a `code_review` line that re-derived the
  # schema-review rule from DATA_MODELING_CONCEPTS — and the third had already
  # drifted that way before, answering "yes" for a data-modeling concept on a
  # parsons_problem third. A restatement here cannot be kept honest by tests
  # that only cover today's kinds: it goes wrong the day a kind gains an
  # exclusion, which is exactly what adding a second concept group did.
  #
  # `mode` is passed only for code_review, the one kind whose selectable
  # vocabulary depends on it; the third slot is never code_review.
  #
  # `language` is the day's actual generation language, deliberately not
  # `cm.language`: for an architecture-bucket concept the two diverge
  # (cm.language is the pseudo-language "architecture"), and LANGUAGE_CONFIG
  # happens to carry an "architecture" entry of its own for concept-reference
  # generation — passing cm.language through would resolve non-architecture
  # kinds against that entry's vocabulary instead of the day's real one,
  # falsely reporting code_review/pattern as hosts for an architecture
  # concept.
  def can_host?(cm, section_key, language, mode: nil)
    ProblemSetIngest.selectable_vocabulary_for(section_key, language, mode: mode).include?(cm.concept)
  end

  # Delivery is advisory, so the only way to know whether retention checks actually
  # land is to record both halves. Logged after ingest so it reflects
  # the concepts actually persisted, not whatever the provider first returned.
  # `tagged` makes a miss diagnosable rather than merely countable: it shows what
  # the model picked instead.
  #
  # Takes a ConceptBucket rather than a language because the fourth slot's
  # track is bucket-scoped and language-independent; for the three-slot track
  # the bucket IS the day's language (see ConceptBucket.for).
  def log_retention(user, bucket, due_checks, problem_set, code_review_mode)
    return if due_checks.empty?

    offered = due_checks.map(&:concept)
    tagged  = problem_set.values.filter_map { |s| s["concept"] if s.is_a?(Hash) }
    honored = offered & tagged

    Rails.logger.info(
      "[retention] user=#{user.id} date=#{Date.current} bucket=#{bucket} " \
      "code_review_mode=#{code_review_mode} " \
      "offered=#{offered.join(',').presence || '-'} " \
      "honored=#{honored.join(',').presence || '-'} " \
      "tagged=#{tagged.join(',').presence || '-'}"
    )
  end

  # Nearly all difficulty adaptation in this app is advisory — the prompt asks
  # the model to ease off reduced-tier concepts or raise the bar after a run
  # of "too easy" ratings, but nothing verifies the returned problem set
  # actually reflects that. This pairs what was requested against what was
  # delivered so a week of production entries can answer whether the loop is
  # working before changing any generation logic on a hunch. Read alongside
  # ResponsesController#log_review_diagnostics (correlated by user_id + date).
  # Safe to remove once that question is settled. See
  # docs/superpowers/plans/2026-08-11-difficulty-diagnostics-logging.md.
  def log_difficulty_diagnostics(user, language, plan, problem_set, history)
    payload = {
      event: "generation",
      user_id: user.id,
      date: Date.current.to_s,
      language: language,
      requested: {
        skill_level: user.skill_level,
        code_review_mode: plan.code_review_mode,
        pattern: plan.pattern,
        third: plan.third,
        fourth: plan.fourth,
        section_count: ExerciseSection.for_plan(pattern: plan.pattern, third: plan.third, fourth: plan.fourth).size,
        reinforcement: plan.reinforcement,
        due_checks: plan.due_checks.map(&:concept),
        established: plan.established.map(&:concept),
        recent_performance: history
      },
      delivered: without_answer_key(problem_set)
    }

    Rails.logger.info("[difficulty_diagnostics] #{payload.to_json}")
  end

  # Log storage is not one of the places the ambiguity hunt's answer key is
  # allowed to reach. Every other consumer of a problem_set renders a closed
  # enumeration of named fields; this is the only one that serializes the whole
  # thing, so the exclusion lives here rather than in a rule the next
  # whole-payload logger would have to remember. Returns a copy — the caller's
  # problem_set is what gets persisted.
  def without_answer_key(problem_set)
    problem_set.transform_values do |section|
      section.is_a?(Hash) ? section.except(ProblemSetIngest::ANSWER_KEY_FIELD) : section
    end
  end

  # Subclasses must implement: makes the provider-specific HTTP call and
  # returns a normalized Hash { text:, input_tokens:, output_tokens: }.
  # `read_timeout` overrides the connection's default read budget for this
  # call only (see AiService::GENERATION_READ_TIMEOUT). `max_tokens`, when
  # given, overrides the provider's own default output ceiling for this call
  # only (see AiService::DUCK_RESPONSE_MAX_TOKENS).
  def call(system:, prompt:, cache_system: false, read_timeout: READ_TIMEOUT, max_tokens: nil)
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

  # JSON schema every provider is asked to return for a problem set. Each kind
  # owns the fragment describing itself (ExerciseSection.schema_fragment); this
  # joins the fragments for whichever kinds today's set holds (two to four).
  # The code-bearing fields' label switches with `language` so instructions
  # never assume Ruby idioms when generating JS — the structure itself never
  # changes across languages.
  def exercise_schema_for(language = "ruby_rails", third: :challenge, fourth: :plan_review, pattern: :pattern)
    label = config_for(language)[:label]

    sections = ExerciseSection.for_plan(third: third, fourth: fourth, pattern: pattern)
                              .map { |kind| kind.schema_fragment(label: label) }
                              .join(",\n  ")

    <<~SCHEMA
      {
        #{sections}
      }
    SCHEMA
  end

  # history defaults to a fresh query so every existing caller (direct specs
  # included) keeps working unchanged; #generate_exercise passes its own
  # already-fetched value instead so the prompt and the diagnostics log
  # never see two different snapshots of the same user's history.
  def build_exercise_prompt(user, language = "ruby_rails", third: :challenge, pattern: :pattern,
                            reinforcement: nil, due_checks: [],
                            established: [], history: user.recent_performance,
                            fourth: :plan_review, fourth_reinforcement: [], fourth_due_checks: [], fourth_established: [],
                            code_review_mode: :application_code)
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
        "#{h[:date]}: #{h[:sections_answered]}/#{h[:sections_total]} answered#{concept_text}#{framing_text}#{feedback}"
      }.join("\n")
    end

    reinforcement_list = reinforcement || user.concepts_needing_reinforcement
    reinforcement_text = reinforcement_list.any? ?
      reinforcement_list.map { |h| "#{h[:concept]} (#{h[:tier]})" }.join(", ") : "none"

    # Both slots resolved once, through the same call the schema assembles
    # from, so guidance, hosting, and schema can never disagree about which
    # kind a slot holds — and a symbol rolled into a slot it can't occupy fails
    # here rather than reaching a kind that has no guidance to give.
    kinds = ExerciseSection.for_plan(third: third, fourth: fourth, pattern: pattern)

    # Advisory, like every other concept instruction here — the model may ignore it.
    # If real-world hit rate turns out low, the fix is to escalate THIS wording
    # toward the directive phrasing used for reinforcement above ("reintroduce
    # every concept listed"). It is not a reason to revisit the schedule, the data
    # model, or the decision not to track delivery.
    # filter_map, not map: a due concept no section can host today annotates as
    # nil and is dropped, so the block disappears entirely rather than listing
    # a concept the prompt cannot ask for.
    annotated_due_checks = due_checks.filter_map { |cm| annotate_retention_concept(cm, kinds, language, code_review_mode) }

    retention_block =
      if annotated_due_checks.any?
        <<~RET.chomp

          Retention checks due today: #{annotated_due_checks.join(', ')}
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
          - If you were already going to select one of these for a section's concept, keep that section's teaching_note minimal (a single short sentence, or an empty string is fine).
          - Pitch at full difficulty — do not ease, simplify, or add scaffolding for these, the same as you would not for a retention check.
          - This is advisory, like every other concept instruction here: it does not force you to select one of these concepts, only shapes the section if you do.
        EST
      else
        ""
      end

    fourth_reinforcement_text = fourth_reinforcement.any? ?
      fourth_reinforcement.map { |h| "#{h[:concept]} (#{h[:tier]})" }.join(", ") : "none"

    fourth_reinforcement_line =
      if fourth
        "Fourth-section (#{fourth}) concept needing reinforcement: #{fourth_reinforcement_text}"
      else
        ""
      end

    fourth_retention_block =
      if fourth_due_checks.any?
        <<~RET.chomp

          Retention check due for the fourth section today: #{fourth_due_checks.map(&:concept).join(', ')} (#{fourth} bucket).
          - This is a concept the engineer previously MASTERED in this skill. Work it into the fourth section as its concept.
          - Use a completely FRESH scenario — never reuse a prior framing. Pitch at FULL difficulty, no extra scaffolding — the engineer is not struggling with this, making it easier defeats the point of checking.
        RET
      else
        ""
      end

    fourth_established_block =
      if fourth_established.any?
        <<~EST.chomp

          Established fourth-section concept (well past first mastery, survived a retention check): #{fourth_established.map(&:concept).join(', ')}
          - If you were already going to select this for the fourth section's concept, keep the teaching_note minimal and pitch at full difficulty, the same as you would for any other established concept.
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

    config = config_for(language)
    label  = config[:label]
    focus  = user.focus_areas.any? ? user.focus_areas.join(", ") : "general #{label} patterns"

    # Each chosen kind gives its own guidance line, keyed off the same `kinds`
    # the schema and retention hosting derive from — so guidance can never
    # disagree with what the schema actually asks for. code_review is the only
    # kind whose guidance depends on the day's content mode.
    sections_guidance = kinds.map { |kind|
      mode = code_review_mode if kind == ExerciseSection::CodeReview
      generation_guidance_for(kind, language, mode: mode)
    }.join("\n")

    <<~PROMPT
      Generate a daily Code Gym exercise set for this engineer.

      Engineer profile:
      - Name: #{user.name}
      - Skill level: #{user.skill_level} (beginner → developing → solid → strong)
      - Priority focus areas: #{focus}

      Recent performance (last 10 sessions):
      #{history_text}

      Concepts needing reinforcement right now: #{reinforcement_text}
      #{fourth_reinforcement_line}

      Instructions:
      - If they've been rating exercises "too easy", increase difficulty and reduce explanation in the reference.
      - If they've been rating "too hard" or skipping sections, simplify and add more scaffolding.
      - Prioritize focus areas they've missed or rated hard recently.
      - Rotate between topics across sessions — avoid the same pattern two days in a row.
      - Vary the concrete business-domain scenario and code structure across sessions, not just the concept — do not reuse the class/method names or narrative framing shown in the "framings:" notes above.
      #{ts_guidance}
      - Prefer drawing each section's business-domain scenario from real, job-adjacent flavors like: #{scenario_domain_list} (adapt any flavor to fit the day's stack — e.g. a Rails day's "component state management" becomes a service/controller state concern instead). Use a legacy GraphQL maintenance scenario (e.g. "a legacy GraphQL layer needs a fix") only rarely — at most roughly 1 in every 8-10 sessions — purely as scenario framing, never as the tagged concept.
      - Each teaching_note must point toward how to think about the problem or the right question to ask — one or two sentences, never the full answer.
      - answer_scaffold (pattern and architecture only): #{ExerciseSection::MAX_SCAFFOLD_LABELS} labels at most, #{ExerciseSection::MAX_SCAFFOLD_LABEL_LENGTH} characters at most each, ending in a colon. These pre-fill the answer box, so write them for THIS question specifically — name the parts a complete answer to it must cover, in the order someone should think them through (e.g. for a caching decision: "Which option, and why:", "How you'd handle a stale entry:"). Generic prompts that would fit any question of this kind are a wasted scaffold. Each is a heading the engineer writes UNDER, so it must ask for something, never state or hint at the answer — the teaching_note rules apply here too.
      - Every "diagram" field is Mermaid source using ONLY `flowchart TD` or `graph LR`. Maximum 8 nodes. No styling directives, no subgraphs, no click handlers, no classDef — narrow syntax parses reliably, clever syntax does not. Node labels must be short (a few words); use quoted labels like A["Order service"] when a label contains spaces or punctuation.
      - A section's "diagram" depicts ONLY the structure its scenario or snippet already describes — the components, calls, state, and consumers as written, in the order they happen. Never diagram the fix, the corrected structure, or the answer, and never annotate a node as the problem, the bug, or the bottleneck. The engineer sees this BEFORE answering, so showing the shape of a problem must never reveal its solution.
      - When the snippet or scenario contains a loop, iteration, or repeated invocation that wraps the flow being diagrammed (e.g. a method called inside `each`/`for`/`while`), the diagram must make that repetition visible — either an explicit loop/iteration node in the call's path, or a labeled edge stating the per-item cardinality (e.g. "once per customer", "for each order"). A flat one-time call chain is not accurate for code that actually repeats. Do not manufacture a loop or cardinality label when the snippet has none.
      - Return an empty string for any "diagram" when a picture would not add anything beyond the text. An empty string is a perfectly good answer and is preferred over a forced or trivial diagram.
      #{sections_guidance}
      #{data_modeling_idiom_guidance}
      #{meta_skill_framing_guidance}
      #{code_smell_naming_guidance}
      #{oo_design_violation_guidance}
      #{module_design_depth_guidance}
      - Reduced-tier concepts: for any concept marked `(reduced)`, keep the SAME concept and vocabulary — never silently swap in a different, easier concept. Ease the difficulty only: simpler framing, a smaller scenario, more scaffolding/starter code, and a teaching_note that guides more directly toward the key insight (it may name the technique, but not the full answer).
      - Mastery loop: reintroduce every concept listed as "needing reinforcement right now" above (both standard and reduced tiers) with a fresh code example and framing — never a repeat snippet. A concept exits reinforcement only on full mastery: the user's self-rating for that section was "right level"/"too easy" AND the AI rated it "solid"/"strong". Short of that, steady improvement (a better AI rating than last time) still counts as progress — keep reinforcing, and let the tier annotation tell you how hard to pitch it.
      #{retention_block}
      #{established_block}
      #{fourth_retention_block}
      #{fourth_established_block}
      - Concepts most recently rated "too easy" must not repeat within the same week.
      - Concepts most recently rated "right level" have no special weighting.

      Return JSON matching this schema exactly:
      #{exercise_schema_for(language, third: third, fourth: fourth, pattern: pattern)}
    PROMPT
  end

  # Data-modeling concepts sit in both language vocabularies, so pattern — and
  # any rotating third except parsons_problem, which excludes them — can draw
  # one on any day. That reachability is the point (a due retention check must
  # have somewhere to land when code_review isn't in schema-review mode). What
  # it must not do is turn those sections into a second schema review: only a
  # schema-review code_review presents an artifact. Stated once, for every
  # section, rather than repeated into each kind's guidance, since it is a rule
  # about the concept and not about any one kind.
  #
  # The sentence defers to each section's own vocabulary list rather than
  # claiming every section: a kind that excludes the group would otherwise read
  # this as license to tag it anyway, and ingest validates against the full
  # vocabulary, so nothing downstream would catch it.
  def data_modeling_idiom_guidance
    "- The data-modeling concepts (#{DATA_MODELING_CONCEPTS.join(', ')}) may be tagged on any section whose own " \
      "vocabulary list above includes them. " \
      "Only a schema-review code_review presents a schema artifact to review — anywhere else, express the " \
      "concept in that section's own idiom: a pattern question about wrong_cardinality asks how the " \
      "relationship should be modeled and what the wrong shape costs the code that uses it, not for a " \
      "migration to review."
  end

  # The meta-skill concepts name a way of reasoning, which makes them the one
  # group that can quietly cost a section its grade: code_review and challenge
  # have no section_grading_note and are graded by the generic rubric, and that
  # rubric has nothing to put in "missed" if the question had no wrong answer
  # to begin with. So the concept is confined to framing here, once for every
  # section, rather than restated into each kind's guidance — like
  # data_modeling_idiom_guidance, it is a rule about the concept, not the kind.
  def meta_skill_framing_guidance
    "- The meta-skill concepts (#{META_SKILL_CONCEPTS.join(', ')}) name HOW to reason " \
      "about a problem, not a topic to write about. A section tagged with one must still " \
      "contain exactly one specific, findable issue and be gradeable against it — the " \
      "concept shapes only how the question is framed, never whether there is a right " \
      "answer. A code_review tagged reading_for_intent plants one real divergence between " \
      "what the code is evidently for and what it does, and asks the engineer to name both; " \
      "it never asks an open question about the code's purpose. A challenge tagged " \
      "separating_symptom_from_cause states a failing behavior whose obvious fix treats " \
      "the symptom, and is graded on whether the submitted implementation addresses the " \
      "cause; it never asks for an essay about how to debug. Where no code is shown " \
      "(pattern), express the concept against the described design instead: what the " \
      "proposed approach takes for granted, or which layer the real cause sits at."
  end

  def code_smell_naming_guidance
    "- The code-smell concepts (#{CODE_SMELL_CONCEPTS.join(', ')}) name a shape to recognize, not a single " \
      "broken line. When one is a section's tagged concept, the code must exhibit it at a scale where it is " \
      "visible — a class doing four jobs, a change that would touch six call sites — and the answer is naming " \
      "and locating the smell and saying what it costs, never patching one line. Express it in the host " \
      "section's own idiom: on a test-file code_review, a god_object is a bloated test class. The challenge " \
      "section is the exception to the answer shape, since its answer is code: there the exercise is a " \
      "refactor — starter_code exhibits the smell at that scale and the question asks the engineer to " \
      "restructure it, so writing the better shape IS the answer rather than describing it."
  end

  # A principle is a rule, not a thing to find, which makes this the group most
  # likely to produce a section with no wrong answer in it: code_review and
  # challenge have no section_grading_note and are graded by the generic
  # rubric, which has nothing to put in "missed" if nothing was missable. So
  # the requirement here is the same one meta_skill_framing_guidance enforces —
  # the concept frames the question, it never replaces the findable issue.
  # Stated once for every section, like the other three group rules, because it
  # is a rule about the concept and not about any one kind.
  def oo_design_violation_guidance
    "- The OO design-principle concepts (#{OO_DESIGN_CONCEPTS.join(', ')}) name a rule the code breaks, not a " \
      "topic to discuss. A section tagged with one must contain exactly one specific, findable violation of that " \
      "rule and be gradeable against it, and the answer is naming the violation and saying which future change it " \
      "makes hard, rather than a rewrite of the class. Express it in the host section's own idiom: a code_review " \
      "tagged open_closed shows a conditional that must be edited every time a variant is added; a pattern, which " \
      "shows no code, describes a hierarchy built for reuse and asks what the composed shape would be and what it " \
      "costs. The challenge section is the exception to the answer shape, since its answer is code: there the " \
      "starter_code violates the principle — a behavior that cannot be tested without reaching through a " \
      "hard-coded collaborator, for dependency_inversion — and the question asks for the version that satisfies " \
      "it, so writing the corrected design IS the answer rather than describing it."
  end

  # Depth is a property of an interface, not a defect in a result, which makes
  # this the group most able to produce a section with nothing missable in it —
  # the same failure oo_design_violation_guidance and meta_skill_framing_guidance
  # each guard against, since code_review and challenge carry no
  # section_grading_note and the generic rubric has nothing to put in "missed".
  # Stated once for every section, like the other four group rules, because it
  # is a rule about the concept and not about any one kind.
  def module_design_depth_guidance
    "- The module-design concepts (#{MODULE_DESIGN_CONCEPTS.join(', ')}) name what a module's interface costs " \
      "every caller, not a bug in what it computes. A section tagged with one must contain exactly one specific, " \
      "findable instance of that shape and be gradeable against it, and the answer is naming the instance and " \
      "saying which future change its interface makes expensive, rather than a rewrite of the module. Express it " \
      "in the host section's own idiom: a code_review tagged pass_through_method shows a method whose entire body " \
      "forwards its arguments to one collaborator; on a test-file code_review, a shallow_module is a test helper " \
      "whose setup arguments spell out the very state it claims to hide; a pattern, which shows no code, " \
      "describes a module's interface and asks what it actually hides and what it forces every caller to know " \
      "anyway. The challenge section is " \
      "the exception to the answer shape, since its answer is code: there the starter_code exhibits the shape — " \
      "for temporal_decomposition, a flow split into objects that exist only because they run in that order — and " \
      "the question asks for the version organized around information instead, so writing the deeper module IS " \
      "the answer rather than describing it."
  end

  # A kind's generation instructions. The vocabulary comes from
  # ProblemSetIngest.selectable_vocabulary_for, which is always a subset of
  # what ingest validates against — so the guidance can never name a concept
  # the normalizer would then rewrite away, and never has to name one the
  # kind's own format cannot express.
  #
  # Every kind gets the same context and reads what it needs (see
  # ExerciseSection.generation_guidance). No branch on which kind this is:
  # one lived here for code_review's mode arguments, which put per-kind
  # knowledge back into the shared assembler that .generation_guidance exists
  # to keep it out of.
  def generation_guidance_for(kind, language, mode: nil)
    config = config_for(language)

    kind.generation_guidance(
      vocabulary:     ProblemSetIngest.selectable_vocabulary_for(kind.key, language, mode: mode),
      label:          config[:label],
      mode:           mode,
      artifact:       config[:schema_artifact],
      test_framework: config[:test_framework]
    )
  end

  def build_review_day_context(coach, exercise, daily_response)
    keys    = exercise.active_section_keys
    answers = daily_response.answers
    ratings = daily_response.section_ratings

    sections = keys.map do |key|
      ExerciseSection.for(key).review_context(
        section: exercise.problem_set[key], answer: answers[key], rating: ratings[key]
      )
    end

    others = keys.size - 1
    others_clause =
      case others
      when 0 then "no other sections today"
      when 1 then "the other section is"
      else "the other #{others} sections are"
      end

    <<~CONTEXT
      You are a senior #{coach} engineer giving direct, specific feedback on a junior/mid engineer's Code Gym answers. You will grade exactly one of the day's #{keys.size} sections in a follow-up instruction — #{others_clause} given here only so your calibration of "developing" vs. "solid" stays consistent across the whole day. Be honest and constructive. Return JSON.

      #{sections.join("\n\n")}
    CONTEXT
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
    kind = ExerciseSection.for(section)
    kind.improved_code? ?
      "the #{kind.improved_code_label.downcase} for this section" :
      "must be an empty string for this section"
  end

  def section_grading_note(exercise, daily_response, section)
    ExerciseSection.for(section).grading_note(
      section: exercise.problem_set[section] || {}, answer: daily_response.answers[section]
    )
  end

  def build_concept_reference_prompt(concept, config)
    label = config[:label]
    code_example_desc =
      if LANGUAGE_AGNOSTIC_VOCABULARIES.include?(config[:concepts])
        "illustrative pseudocode or a short language-agnostic snippet, ~15 lines"
      else
        "annotated #{label} code, ~15 lines"
      end

    # A shape you find is never a technique to choose, so the remedy lens the
    # other concepts get would have the provider explain when to reach for a
    # god object, a shallow module, or an unknown unknown. The design
    # principles deliberately stay on the remedy lens: open_closed IS
    # something to reach for.
    senior_lens_desc =
      if ANTI_SHAPE_CONCEPTS.include?(concept)
        "how to catch it early, what it costs to leave in place, and when the cheaper-looking shape is still worth refusing"
      else
        "when to reach for it / tradeoffs"
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
        "senior_lens":  "string — #{senior_lens_desc}"
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

  # Parsons correctness is decided in Ruby, never by the model — whatever rating it returned
  # is discarded and replaced. Skipped when the stored section has no blocks, since there is
  # nothing to grade against and the grader would report a spurious perfect score. Operates on
  # a single un-nested section hash — the shape #review_sections works with.
  def override_parsons_section_rating!(review, exercise, daily_response)
    parsons = exercise.parsons_problem
    return review unless parsons.is_a?(Hash)

    blocks = Array(parsons["blocks"])
    return review if blocks.empty?

    submitted = ExerciseSection::ParsonsProblem.submitted_order(daily_response.answers["parsons_problem"], blocks.size)
    review["rating"] = ExerciseSection::ParsonsProblem.grade(submitted, blocks.size)[:rating]
    review
  end

  # Never allowed to break generation — a bug here is a lost analytics
  # signal, not a reason to fail the request.
  #
  # Rescued per suggestion, not around the loop: a single malformed or
  # transiently failing name would otherwise discard every suggestion behind
  # it, which is how one bad concept costs a whole day's analytics.
  def record_suggested_concepts(suggestions)
    suggestions.each { |suggestion| record_suggested_concept(suggestion) }
  end

  def record_suggested_concept(suggestion)
    SuggestedConcept.record!(language: suggestion.bucket, name: suggestion.name)
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
  #
  # The connection checkout wraps only #log_usage, not the `call` above it —
  # `call` is the provider HTTP round trip, the one part of this method with
  # no DB work in it, and it's shared by #review_sections' per-section
  # threads (see that method's comment). A caller that already holds a
  # connection (every non-threaded caller, via Rails' request-cycle checkout)
  # sees a harmless no-op here: ActiveRecord's with_connection reuses a
  # connection already leased to the current thread rather than checking out
  # a second one.
  def call_and_log(user, purpose:, system:, prompt:, cache_system: false,
                   read_timeout: READ_TIMEOUT, max_tokens: nil)
    result = call(system: system, prompt: prompt, cache_system: cache_system,
                  read_timeout: read_timeout, max_tokens: max_tokens)
    ActiveRecord::Base.connection_pool.with_connection { log_usage(user, result, purpose: purpose) }

    if result[:truncated]
      raise TruncatedResponseError,
            "Provider stopped generating at its output token limit (#{result[:output_tokens].to_i} tokens)"
    end

    result
  end
end
