require "json"

class AiService
  # http_status, quota_id (the limit a 429 hit) and retry_after feed ProviderFailure and the usage row; never shown.
  class Error < StandardError
    attr_reader :http_status, :quota_id, :retry_after
    # Set by call_and_log, so a stored failure names the provider tried even after the user switches.
    attr_accessor :provider

    def initialize(message = nil, http_status: nil, quota_id: nil, retry_after: nil)
      super(message)
      @http_status = http_status
      @quota_id    = quota_id
      @retry_after = retry_after
    end
  end

  # Bad or revoked key (401/403, or Gemini's 400 API_KEY_INVALID); never worth retrying.
  class AuthenticationError < Error; end

  # A 429 that survived Faraday's own retries.
  class RateLimitError < Error; end

  # Out of credit or over a spend limit; providers separate it from a 429 rate limit, since waiting won't clear it.
  class BillingError < Error; end

  # An ended or switched-off trial on an account with no key of its own; raised before anything is sent.
  class TrialEndedError < Error; end

  # A trial's daily cap or the house key's guard is used up; retry_after is the wait until the count resets.
  class TrialAllowanceError < Error; end

  # No HTTP answer and no timeout: a refused connection, a reset or a DNS failure.
  class NetworkError < Error; end

  # Kept apart so callers can explain it in the user's terms instead of showing Faraday's socket message.
  class TimeoutError < Error; end

  # Malformed JSON or the wrong shape; usually a bug in our prompt or schema, not something the user can fix.
  class InvalidResponseError < Error; end

  # Hit the output token cap; named so the unfinished JSON doesn't read as a generic parse error.
  class TruncatedResponseError < InvalidResponseError; end

  # A safety refusal: a 200 with no text, named so it isn't misread as an empty-response parse error.
  class RefusalError < Error; end

  # A configuration mistake, such as a capped call to a model that can't turn thinking off; an Error so rescues catch it.
  class UnsupportedRouteError < Error; end

  # Every section rejected, retries included; no empty day is written, and the dashboard shows this message.
  class AllSectionsRejectedError < Error
    def initialize(message = "Every section of today's draft failed its quality check, so no set was saved. Try generating again.")
      super
    end
  end

  # The longest #review chain must stay under DailyResponse::REVIEW_CLAIM_STALE_AFTER; ai_service_spec asserts it.
  OPEN_TIMEOUT = 10
  READ_TIMEOUT = 45

  # Generation runs on the worker and can wait; SYNC_ is uncalled but bounds future sync callers and one-section retries.
  GENERATION_READ_TIMEOUT      = 300
  SYNC_GENERATION_READ_TIMEOUT = 90
  RETRY_READ_TIMEOUT           = SYNC_GENERATION_READ_TIMEOUT

  # Above READ_TIMEOUT so the call counts as long_running and a timeout isn't retried into duplicate spend.
  CONCEPT_REFERENCE_READ_TIMEOUT = SYNC_GENERATION_READ_TIMEOUT

  # Slowest measured grades took about 80s; above READ_TIMEOUT also makes a timeout final instead of retried and rebilled.
  REVIEW_READ_TIMEOUT = 120

  # One attempt only, added to the review claim's budget; the judge never retries.
  REVIEW_JUDGE_READ_TIMEOUT = 30

  # Every provider's RETRY_OPTIONS share this policy, so timeout budgets read one number.
  RETRY_MAX          = 2
  RETRY_MAX_INTERVAL = 8

  # A poller must pass the same read timeout the call it waits on uses, or it under-waits.
  def self.call_budget_seconds(read_timeout)
    (read_timeout * (RETRY_MAX + 1)) + (RETRY_MAX * RETRY_MAX_INTERVAL)
  end

  # Counts every attempt even when the read timeout is final, since a 429 or 5xx still retries.
  def self.worst_case_call_seconds(read_timeout)
    call_budget_seconds(read_timeout) + ((RETRY_MAX + 1) * OPEN_TIMEOUT)
  end

  def self.single_attempt_call_seconds(read_timeout)
    OPEN_TIMEOUT + read_timeout
  end

  # Only the version that ships is edited and re-judged, so the re-judge call is counted once.
  JUDGED_GENERATION_BUDGET = worst_case_call_seconds(GENERATION_READ_TIMEOUT) +
                             worst_case_call_seconds(READ_TIMEOUT) +
                             (ExerciseSection.all.map(&:judge_retries).max *
                               (worst_case_call_seconds(RETRY_READ_TIMEOUT) + worst_case_call_seconds(READ_TIMEOUT))) +
                             (ExerciseSection.all.any?(&:rejudge_edits?) ? worst_case_call_seconds(READ_TIMEOUT) : 0)

  # Timeouts on long_running calls are final: the provider has likely finished and billed the work, so a retry pays twice.
  RETRY_TIMEOUT_GUARD = lambda do |env, exception|
    return false if env.request.context.to_h[:single_attempt]
    return true unless exception.is_a?(Faraday::TimeoutError)

    !env.request.context.to_h[:long_running]
  end

  # A budget, not an enforcement mechanism; one ceiling for every reply, since a client-declared reply type can't be trusted.
  DUCK_RESPONSE_MAX_TOKENS = 400

  # Free prose has no largest valid reply to derive a cap from; passing any max_tokens also turns extended thinking off.
  CONCEPT_ALTERNATE_MAX_TOKENS = 500

  # Server-owned so its wording sits beside the prompt it is tuned against; it counts against the turn cap like any message.
  DUCK_EXPLAIN_REQUEST = "Explain what this exercise is asking, in plain language."

  # Derived from the largest valid critique, since a flat cap truncated maximal replies mid-JSON.
  PSEUDOCODE_CRITIQUE_JSON_OVERHEAD_TOKENS = 100
  PSEUDOCODE_CRITIQUE_MAX_TOKENS =
    (ExerciseSection::PseudocodeToCode::MAX_CRITIQUE_POINTS *
      ExerciseSection::PseudocodeToCode::MAX_CRITIQUE_POINT_LENGTH / 3) +
    PSEUDOCODE_CRITIQUE_JSON_OVERHEAD_TOKENS

  # Both margins are chosen, not measured; a tight cap loses the note silently, and any max_tokens turns thinking off.
  DIFFICULTY_ASSESSMENT_JSON_OVERHEAD_TOKENS = 150
  DIFFICULTY_ASSESSMENT_CHARS_PER_TOKEN = 2.5
  DIFFICULTY_ASSESSMENT_OVERRUN_HEADROOM = 2
  DIFFICULTY_ASSESSMENT_MAX_TOKENS =
    ((ExerciseSection::MAX_SECTIONS *
      (DailyResponse::MAX_DIFFICULTY_REASON_LENGTH / DIFFICULTY_ASSESSMENT_CHARS_PER_TOKEN) *
      DIFFICULTY_ASSESSMENT_OVERRUN_HEADROOM) +
      DIFFICULTY_ASSESSMENT_JSON_OVERHEAD_TOKENS).ceil

  # Bounds how long one hung provider connection can hold the review request for an optional note.
  DIFFICULTY_ASSESSMENT_GRACE_SECONDS = 5

  # Provider output rendered into the page, so bounded at the boundary.
  MAX_GENERATED_CODE_LENGTH = 8_000

  # One rule shared by two prompts so it cannot be edited in one without the other.
  def self.explain_differently_standard(subject)
    "Explain the SAME #{subject} again using a genuinely different approach — a\n" \
      "different analogy, a different level of abstraction, or a concrete worked\n" \
      "scenario instead of a principle. Do not repeat the original wording."
  end

  # CLAUDE.md's Writing style list mirrors this (a spec checks); defined above DUCK_SYSTEM_PROMPT, which interpolates it.
  PLAIN_LANGUAGE_STANDARD = <<~STANDARD.chomp.freeze
    Write prose for the engineer this way:

    Avoid, in order of how often these actually show up:
    - Manufactured rhetorical contrast — "not X, but Y" used purely for punch when a plain sentence says the same thing.
    - Buzzwords and jargon. Use the plain-language equivalent; if a technical term is genuinely necessary, define it briefly on first use.
    - Placeholder phrases — "please note," "at this time," "it's worth mentioning."
    - Overusing "please" in instructions — state it directly.
    - Starting every sentence with the same construction.
    - Exclamation points, outside genuine, rare emphasis.
    - Forced cleverness or trying to sound entertaining.
    - Both choppy fragments and long-winded run-ons.

    Aim for:
    - Active voice — make clear who or what is doing the thing.
    - Second person, direct address.
    - Concrete over abstract — a specific example beats a general description of the same idea.
    - Conditions before instructions, not after.
    - Natural rhythm — if a sentence sounds stilted read aloud, rewrite it.

    Calibration: too informal ("This is a total game-changer!") and too formal/overwrought ("The interface undergoes a paradigmatic transformation") are both wrong; aim for the plain middle ("This changes how the interface works").
  STANDARD

  # A rating means the same at every pitched level; each kind's grading note must not restate these levels.
  RATING_RUBRIC = <<~RUBRIC.chomp.freeze
    How to choose "rating": rate the answer against the level its section was pitched at, which the grading instruction states on its "Pitched at" line, so a rating means the same thing at every level. Base it on the gaps you list in "missed". A gap is essential when, left as the engineer wrote it, the code or decision would behave wrongly or a requirement the problem states would go unmet. Missing syntax, polish or wording, or a step any engineer at this level would take for granted, is not essential and does not lower the rating. Judge what is essential against the problem as written: a problem simpler than its level's description is graded on what it actually asks. Each section's grading note says what its main point and its essential pieces are.
    - "beginner": missed the main point of the section.
    - "developing": found the main point, but missed or misexplained at least one essential piece.
    - "solid": no essential misses.
    - "strong": solid, plus something the question did not ask for that matters here, such as a tradeoff or a consequence.
    The rating must agree with "missed": when "missed" names an essential gap, the rating is not "solid" or "strong". When a section's grading note says its rating is already fixed, that note wins.
  RUBRIC

  # Raise when RATING_RUBRIC changes what a rating means; that restarts every Automatic account's earned size at two.
  RUBRIC_VERSION = 1

  PSEUDOCODE_CRITIQUE_SYSTEM_PROMPT = <<~PROMPT.chomp
    You are reviewing an engineer's PSEUDOCODE plan before any code exists. They
    have not submitted or been graded. Your job is to point out genuine gaps in
    the plan's reasoning, and nothing else.

    #{ExerciseSection::PseudocodeToCode.gap_standard}

    Never write code, never show a corrected plan, and never restate their plan
    back to them. Name what breaks and why, in one or two sentences per point.

    If the plan holds up, say so by returning "gaps_found": false with an empty
    "gaps" array. Do NOT invent a point to seem useful — an empty result is a
    valid and expected outcome.

    Return a single JSON object:
    {"gaps_found": true|false, "gaps": ["string", "..."]}
    At most #{ExerciseSection::PseudocodeToCode::MAX_CRITIQUE_POINTS} entries in "gaps".
    "gaps" must be empty when "gaps_found" is false, and non-empty when it is true.
  PROMPT

  # Stated as prohibitions because a model reads the adjective "faithful" generously, and drift turns this into free help.
  PSEUDOCODE_TRANSLATE_SYSTEM_PROMPT = <<~PROMPT.chomp
    You translate an engineer's pseudocode into real code. You are a
    TRANSCRIBER, not a reviewer and not an assistant. You do not improve
    anything.

    - If the pseudocode omits an edge case, the code omits it too. Do not add a
      guard, a nil check, a bounds check, or a default the pseudocode did not state.
    - If the pseudocode is ambiguous, pick the MOST LITERAL reading and implement
      that. Do not pick the reading that would work better.
    - If the pseudocode is wrong, implement the wrong thing. Do not fix it.
    - Do not add error handling, logging, validation, or defensive checks.
    - Do not add comments. In particular, never add a comment pointing out a
      problem ("# note: this will fail on empty input"). Naming the flaw is
      someone else's job, not yours.
    - Do not rename, reorder, or restructure for clarity.
    - Add ONLY what is required to make the result syntactically valid:
      declarations, signatures, brackets, imports.

    Return the code and nothing else — no prose, no explanation, no fences.
  PROMPT

  DUCK_SYSTEM_PROMPT = <<~PROMPT.chomp
    You are a Socratic thinking partner helping an engineer work through a
    problem they have NOT yet submitted or been graded on.

    Every message they send is one of two kinds. Decide which before replying.

    1. UNDERSTANDING THE PROBLEM — they are asking what the exercise means, what
       a term or a piece of the snippet does, or for a plainer restatement of the
       question. Examples: "what is this even asking?", "what does memoization
       mean?", "explain this scenario simply", "what does this line do?"
       Answer these DIRECTLY, with one concrete everyday analogy if it helps.
       Describe only what is already on their
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

    #{PLAIN_LANGUAGE_STANDARD}
  PROMPT

  # Sized for five prose fields (Pattern's count); the headroom bounds a model overrunning, and the cap turns thinking off.
  JUDGE_MAX_TOKENS = 1_200

  # Fetched by name in JudgeVerdict::PRINCIPLES' order, so a new principle fails loudly here instead of reaching the judge.
  JUDGE_PRINCIPLE_GUIDANCE = {
    "scope_mismatch" => "answering correctly does not require the tagged concept, or the question asks for something the concept does not cover.",
    "unstated_prerequisite" => "solving depends on important knowledge that is neither the tagged concept nor supplied by the problem, and a brief clarifying phrase could not reasonably supply it.",
    "underdetermined" => "information needed for a defensible answer is missing and is not present or implied anywhere in the draft.",
    "reasoning_failure" => "measured against the kind's task, the wording structurally gives away the defect's location or the solution, or otherwise makes the task impossible as designed. Structural only: a removable leaking sentence is an edit."
  }.freeze

  JUDGE_PRINCIPLE_LINES = JudgeVerdict::PRINCIPLES
    .map { |principle| "- #{principle}: #{JUDGE_PRINCIPLE_GUIDANCE.fetch(principle)}" }
    .join("\n").freeze

  JUDGE_SYSTEM_PROMPT = <<~PROMPT.freeze
    You are checking one section of a generated coding exercise before an engineer sees it. You judge the section as written; you are not told what its author intended.

    A question may be difficult, unfamiliar, or conceptually demanding. Its difficulty must come from the intended reasoning task, not from unclear wording, missing information, or accidental prerequisites. Reject when the problem itself is broken. Edit when the problem is sound but poorly expressed. Never reject a problem for being hard.

    Work through these checks internally, in this order, and stop at the first rejection. Reply with only the JSON verdict, with no text before or after it.
    1. Answerable. Can a knowledgeable developer at the stated level reach a defensible answer without guessing which scenario the author meant? Normal technical inference is allowed. The section is unanswerable only when materially different readings are possible and the answer depends on picking the author's. If prose can close the gap, that is an edit, on one condition: a clarification may only surface what the draft already shows or implies, such as behaviour visible in the code that the prose never states. If the missing information is not in the draft at all, you have no source for it: reject as underdetermined. Never invent facts.
    2. Valid. Check the remaining rejection principles.
    3. Improvable. If the section is sound, rewrite its prose fields where one of the listed issues applies, or return keep.

    Rejection principles, the only #{JudgeVerdict::PRINCIPLES.size}:
    #{JUDGE_PRINCIPLE_LINES}

    Never reject because a section is straightforward, familiar, hard, unfamiliar, or names its concept. The tagged concept may be new to the engineer; a reference explains it beside the section, so unfamiliarity with it is never grounds for rejection. Judge against the stated level, not any notion of a typical engineer: a section at principal level is supposed to be difficult. You never change difficulty: the draft already pitched this section, and you preserve that pitch and the task exactly.

    Leakage means revealing where the defect is or what the answer is. It does not mean naming the domain or the tagged concept. "What vulnerability exists in this endpoint?" is the intended framing for a security review, not leakage.

    Edits rewrite prose fields only. The teaching note is a hint the engineer can reveal after attempting, so it gets the same prose rules and must not alter the task. Issues, the only #{JudgeVerdict::ISSUE_TYPES.size}: #{JudgeVerdict::ISSUE_TYPES.join(", ")}.

    When you edit: never modify code or schema content, the tagged concept, the kind, or any field that carries the planted defect. Never change the task or the difficulty; never make a subtle flaw more obvious or an obvious one more obscure. Never add a technical claim the draft does not make or imply. Never add information only to make the answer easier to find, and never solve the exercise. Never remove or genericize the scenario setting; trim filler inside a statement, never the setting. Return exactly the fields you were asked to rewrite, nothing else.

    For any prose you rewrite:
    #{PLAIN_LANGUAGE_STANDARD}

    Return only JSON, one of:
    {"status":"keep"}
    {"status":"edit","issues":[{"type":"...","evidence":"<quoted text>"}],"fields":{"<prose field>":"<rewritten>"}}
    {"status":"reject","principle":"...","evidence":"<quoted text>","reason":"<one or two sentences>"}
  PROMPT

  # ai_service_spec asserts REVIEW_JUDGE_MAX_TOKENS' headroom over this; a run past a quarter of it needs a decision.
  REVIEW_JUDGE_MEASURED_MAX_OUTPUT_TOKENS = 371

  # Review output is unbounded, so a long review can still fall back as `truncated`; passing this turns thinking off.
  REVIEW_JUDGE_MAX_TOKENS = 1_500

  # Hedging and multi-topic next steps are not listed here: fixing them changed what reviews said (2026-10-09 comparison).
  REVIEW_PROSE_ISSUE_GUIDANCE = {
    "plain_language_violation" => "jargon or buzzwords where a plainer word works, filler such as \"basically\" or \"at the end of the day\", or a miss explained in a more complicated way than it needs.",
    "verbosity" => "the same point made twice, the rating restated in prose, or filler."
  }.freeze

  REVIEW_PROSE_ISSUE_LINES = ReviewProseVerdict::ISSUE_TYPES
    .map { |type| "- #{type}: #{REVIEW_PROSE_ISSUE_GUIDANCE.fetch(type)}" }
    .join("\n").freeze

  REVIEW_PROSE_JUDGE_SYSTEM_PROMPT = <<~PROMPT.freeze
    You are editing the prose of one section's code review so the engineer who submitted the work can read it easily. The grade is final: you change how the review says things, never what it says.

    Check for these problems, the only #{ReviewProseVerdict::ISSUE_TYPES.size}:
    #{REVIEW_PROSE_ISSUE_LINES}

    #{PLAIN_LANGUAGE_STANDARD}

    Rules for any rewrite:
    - Keep what every entry claims. Keep each negation ("does not", "never"), each condition ("only when", "unless"), and every identifier (a method, column, constant or file name) exactly as written.
    - Never add a claim, a fix or an example the entry does not already make. Never touch code.
    - Keep how sure each claim is. A word that limits a claim ("may", "often", "in some cases") stays, and a vague claim stays vague: "this could get slow with lots of rows" can become "this may get slow with lots of rows", never "this times out with lots of rows".
    - Keep every topic a next step names. Shorten how it says them; never choose some and drop the rest.
    - A list field is rewritten as entries, each with "from": the zero-based indexes of the original entries it replaces. Cite every original index exactly once. Merge entries only when they make the same point, and then report a verbosity issue. Order entries by their first index.
    - Rewrite only the fields that have a problem and leave the others out. If nothing needs changing, return keep.
    - Each issue's evidence quotes the text it is about.

    Work through this internally, then reply with only the JSON verdict, with no text before or after it.
  PROMPT

  # Closed vocabularies: anything a provider returns outside the active list is normalized to "other".

  # In both language vocabularies because ConceptBucket dispatches on section key, and this mode's key is still code_review.
  DATA_MODELING_CONCEPTS = %w[
    missing_index wrong_cardinality missing_constraint
    denormalization_tradeoffs unsafe_migration
  ].freeze

  # Outside LANGUAGE_AGNOSTIC_VOCABULARIES so references show real code; their own bucket would need a section kind.
  META_SKILL_CONCEPTS = %w[
    reading_for_intent spotting_unstated_assumptions separating_symptom_from_cause
  ].freeze

  # Named smells, not remedies; shared across languages because each means the same in a Rails class and a React component.
  CODE_SMELL_CONCEPTS = %w[
    god_object primitive_obsession shotgun_surgery feature_envy
  ].freeze

  # Kept small on purpose: candidates that would generate the same section as an existing concept were cut.
  OO_DESIGN_CONCEPTS = %w[
    open_closed dependency_inversion composition_over_inheritance
  ].freeze

  # What an interface costs its callers; candidates that duplicated shotgun_surgery or open_closed were cut.
  MODULE_DESIGN_CONCEPTS = %w[
    shallow_module pass_through_method temporal_decomposition
  ].freeze

  # Code that runs cleanly and is still wrong; these are remedies to reach for, so they stay off ANTI_SHAPE_CONCEPTS.
  SILENT_CORRECTNESS_CONCEPTS = %w[
    allocation_rounding semantic_input_validation cache_key_completeness
    deterministic_ordering
  ].freeze

  # What a thing is called and which writes change together; disciplines, so off ANTI_SHAPE_CONCEPTS and TRADEOFF_CONCEPTS.
  DOMAIN_MODELING_CONCEPTS = %w[
    ubiquitous_language aggregate_boundaries
  ].freeze

  # Its own constant because ANTI_SHAPE_CONCEPTS names it before ARCHITECTURE_CONCEPTS is defined.
  COMPLEXITY_CAUSE_CONCEPTS = %w[
    cognitive_load unknown_unknowns
  ].freeze

  # Things to find, not choose; references are cached forever, so a remedy framing applied here would never self-correct.
  ANTI_SHAPE_CONCEPTS = (CODE_SMELL_CONCEPTS + MODULE_DESIGN_CONCEPTS + COMPLEXITY_CAUSE_CONCEPTS).freeze

  RAILS_CONCEPTS = (%w[
    n_plus_one transaction_safety memoization service_objects scope_chaining
    idempotency authorization background_jobs caching validations
    callbacks_vs_service query_objects policy_objects indexing concurrency
    error_handling mass_assignment_protection sql_injection_prevention
    over_mocking testing_implementation_not_behavior
  ] + DATA_MODELING_CONCEPTS + META_SKILL_CONCEPTS + CODE_SMELL_CONCEPTS + OO_DESIGN_CONCEPTS +
    MODULE_DESIGN_CONCEPTS + SILENT_CORRECTNESS_CONCEPTS + DOMAIN_MODELING_CONCEPTS).freeze

  JS_CONCEPTS = (%w[
    callback_hell promise_chaining closures prototype_chain event_loop_blocking
    this_binding array_mutation_pitfalls debouncing_throttling closures_in_loops
    memory_leaks_listeners hooks_dependencies component_re_renders state_lifting
    controlled_vs_uncontrolled xss_prevention insecure_client_storage
    generics type_guards_narrowing union_intersection_types mapped_conditional_types
    over_mocking testing_implementation_not_behavior
  ] + DATA_MODELING_CONCEPTS + META_SKILL_CONCEPTS + CODE_SMELL_CONCEPTS + OO_DESIGN_CONCEPTS +
    MODULE_DESIGN_CONCEPTS + SILENT_CORRECTNESS_CONCEPTS + DOMAIN_MODELING_CONCEPTS).freeze

  # security_review draws only from these, so each concept is practiced as both "is this correct" and "is this exploitable".
  RAILS_SECURITY_CONCEPTS = %w[mass_assignment_protection sql_injection_prevention].freeze
  JS_SECURITY_CONCEPTS    = %w[xss_prevention insecure_client_storage].freeze

  # TypeScript syntax is asked for only in a section tagged with one of these; other JS concepts stay plain JS.
  TYPESCRIPT_FLAVORED_CONCEPTS = %w[
    generics type_guards_narrowing union_intersection_types mapped_conditional_types
  ].freeze

  # Language-independent; used only by the architecture section and its concept references.
  ARCHITECTURE_CONCEPTS = (%w[
    sync_vs_async service_boundaries coupling_cohesion data_consistency_tradeoffs
    caching_strategy build_vs_buy scaling_bottlenecks failure_mode_design
    api_versioning event_driven_vs_request_response data_ownership
    idempotency_at_scale observability_tradeoffs
  ] + COMPLEXITY_CAUSE_CONCEPTS).freeze

  # Written out, not derived, so a new architecture concept needs a decision before it gets this framing; a spec enforces it.
  TRADEOFF_CONCEPTS = %w[
    sync_vs_async service_boundaries coupling_cohesion data_consistency_tradeoffs
    caching_strategy build_vs_buy scaling_bottlenecks failure_mode_design
    api_versioning event_driven_vs_request_response data_ownership
    idempotency_at_scale observability_tradeoffs
    denormalization_tradeoffs
  ].freeze

  # Disjoint from every other vocabulary, so a plan_review concept never appears in another section kind.
  PLAN_REVIEW_CONCEPTS = %w[
    unjustified_constant contradicts_existing_pattern scope_creep silent_behavior_change
  ].freeze

  # Same disjointness rule as PLAN_REVIEW_CONCEPTS.
  AMBIGUITY_HUNT_CONCEPTS = %w[
    undefined_scope_boundary unspecified_edge_cases missing_success_criteria
    unstated_data_implications undefined_permissions_model
  ].freeze

  # Disjoint from every other vocabulary, which lets this kind have its own ConceptBucket (DailyPlan::FOURTH_BUCKET_FOR).
  PSEUDOCODE_TO_CODE_CONCEPTS = %w[
    missing_base_case unhandled_empty_input off_by_one_boundary ambiguous_ordering
    unstated_mutation conflated_responsibilities missing_termination_condition
    undefined_failure_path
  ].freeze

  # Scenario dressing only, never concept-tagged; legacy_graphql_maintenance must never appear as a "concept" value.
  SCENARIO_DOMAINS = %w[
    background_job_processing api_versioning_and_deprecation
    activerecord_query_construction component_state_management
    data_export_and_reporting webhook_delivery rate_limiting
    multi_tenant_data_isolation legacy_graphql_maintenance
  ].freeze

  # Settings from outside work, so a concept can be met without first learning what an invoice run or a tenant is.
  EVERYDAY_SCENARIO_DOMAINS = %w[
    shared_grocery_list recipe_box_and_meal_planner gym_workout_log
    library_book_checkout pet_adoption_listings household_chore_rota
    book_club_reading_list plant_watering_reminders event_rsvp_list
    personal_savings_goals
  ].freeze

  # Job-adjacent days only: a legacy layer is the industry context the everyday pool avoids.
  LEGACY_GRAPHQL_SCENARIO_GUIDANCE =
    "Use a legacy GraphQL maintenance scenario (e.g. \"a legacy GraphQL layer needs a fix\") only rarely — " \
    "at most roughly 1 in every 8-10 sessions — purely as scenario framing, never as the tagged concept.".freeze

  # A spec holds these keys equal to DailyPlan's SCENARIO_FLAVOR_WEIGHTS keys, so every rolled flavor has a pool.
  SCENARIO_POOLS = {
    general: {
      domains:    SCENARIO_DOMAINS,
      intro:      "real, job-adjacent flavors",
      adaptation: "a Rails day's \"component state management\" becomes a service/controller state concern instead",
      rule:       nil,
      legacy:     LEGACY_GRAPHQL_SCENARIO_GUIDANCE
    },
    everyday: {
      domains:    EVERYDAY_SCENARIO_DOMAINS,
      intro:      "everyday settings people already know from daily life",
      adaptation: "a Rails day's \"shared grocery list\" is the model and controller that store and update the list",
      rule:       "Keep the setting's own words plain and familiar: no business back-office terms such as invoices, " \
                  "ledgers, tenants, CSV exports or webhooks, and solving a section must never require knowing how " \
                  "a company's internal systems work.",
      legacy:     nil
    }
  }.freeze

  # One entry per concrete language; "mixed" resolves to one of these before reaching AiService (User#language_for_today).
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
    },
    "pseudocode_to_code" => {
      label:    "language-agnostic",
      concepts: PSEUDOCODE_TO_CODE_CONCEPTS,
      coach:    "algorithm design",
      focus:    "turning an informal plan into something that actually works: base cases, empty input, boundaries, ordering, and the failure paths a plan leaves undefined."
    }
  }.freeze

  # These have no language-specific code, so their concept references use pseudocode.
  LANGUAGE_AGNOSTIC_VOCABULARIES = [ ARCHITECTURE_CONCEPTS, PLAN_REVIEW_CONCEPTS,
                                     AMBIGUITY_HUNT_CONCEPTS, PSEUDOCODE_TO_CODE_CONCEPTS ].freeze

  CONCEPT_REFERENCE_FIELDS = %w[tagline explanation code_example senior_lens].freeze

  # guide_worked_example's stated bound, since a contrastive pair can't fit the two-paragraph cap.
  WORKED_EXAMPLE_BOUND = "At most the two fragments plus four sentences of prose.".freeze

  # Separate from CONCEPT_REFERENCE_FIELDS (read by #explain_concept_differently) and outside the required-field check.
  CONCEPT_GUIDE_FIELDS = %w[guide_plain_language guide_worked_example guide_pitfalls].freeze

  # Outside the required-field check, so a flubbed ladder still leaves a usable reference.
  LADDER_FIELD_FOR      = KindDifficulty::LEVELS.index_with { |level| "ladder_#{level}" }.freeze
  CONCEPT_LADDER_FIELDS = LADDER_FIELD_FOR.values.freeze

  # Many rungs share one generation prompt, so this is tighter than MAX_CONCEPT_GUIDE_LENGTH.
  MAX_LADDER_RUNG_LENGTH = 300

  # A spec renders the worst case from the live vocabularies, so growing one past this fails.
  MAX_LADDER_GUIDANCE_CHARS = 48_000

  # Catches a runaway response: several times the two short paragraphs per field the prompt asks for.
  MAX_CONCEPT_GUIDE_LENGTH = 4_000

  # Shared by the prompts that write and reframe a reference; the reframing call's narrow signature is what holds it.
  CONCEPT_REFERENCE_SCOPE = <<~SCOPE.chomp
    This is a stable explanation an engineer returns to across repeat exposure —
    not tied to any single problem.
  SCOPE

  # All three required, so a partial guide fails and a later backfill retries instead of caching half of one.
  RECOGNITION_GUIDE_FIELDS = %w[questions contrast misfires].freeze

  # #generate_recognition_guide gets no exercise, response or history; that signature, not this text, holds the line.
  RECOGNITION_GUIDE_SCOPE = <<~SCOPE.chomp
    This teaches a PROCESS for recognizing the category, never an ANSWER.
    - Good: "ask whether this interface hides what it should, or makes every caller repeat the same decision."
    - Bad: defining any one concept in the list, such as "shallow_module means the interface is as complex as the implementation". Each concept already has its own reference.
    - Bad: anything that tells the reader what to look for in a particular problem they may be given. Never name or describe a specific planted defect, exercise, or answer.
    It is a lens the reader carries into any problem, not a hint about one.
  SCOPE

  # Keeps exception messages, which reach flash alerts and error trackers, free of large provider output.
  RAW_SNIPPET_LIMIT = 500

  # A house key is paid for by the deployment: usage rows record it, and trial gates run before each call.
  attr_writer :house_key

  def house_key? = @house_key == true

  def initialize(api_key)
    @api_key = api_key
    @conn    = build_connection
  end

  def self.for(user)
    provider = AiProvider.find(user.provider)
    raise Error, "User #{user.id} has no recognized AI provider configured" unless provider
    unless provider.available?
      raise Error, "User #{user.id} has the test-only #{provider.provider_key} provider outside a local environment"
    end

    credential = ProviderCredential.for(user)
    provider.new(credential.key).tap { |service| service.house_key = credential.house }
  end

  # The day a provider counts requests in, for the house-key guard; UTC unless a provider states otherwise.
  def self.quota_day_zone = "UTC"

  def self.quota_day(now)
    start = now.in_time_zone(quota_day_zone).beginning_of_day
    start...start.tomorrow.beginning_of_day
  end

  def self.available? = true
  def self.key_pattern = nil
  # nil only on a bare subclass such as a spec double, whose usage rows then carry no provider.
  def self.provider_key = nil

  # The base answers false; the separate ReviewProseJudge switch decides whether the judge runs at all.
  def self.judges_review_prose? = false

  # plan_notes is what DailyPlan::Result#notes recorded, written onto the row.
  JudgedSet = Data.define(:problem_set, :dropped_sections, :outcomes, :plan_notes) do
    def initialize(problem_set:, dropped_sections:, outcomes:, plan_notes: {})
      super
    end
  end

  Draft = Data.define(:problem_set, :plan, :kinds, :difficulty, :ladders, :history,
                      :prompt_options, :suggested_concepts, :unusable_sections)
  private_constant :Draft

  # `blocking:` means a request thread is waiting; the timeout policy for that stays here (SYNC_GENERATION_READ_TIMEOUT).
  def generate_exercise(user, language: user.language_for_today, blocking: false)
    generate_unjudged_exercise(user, language: language, blocking: blocking).problem_set
  end

  # Drops a planned section ingest refused and records its key, as the judged path does.
  def generate_unjudged_exercise(user, language: user.language_for_today, blocking: false)
    draft   = draft_exercise(user, language: language, blocking: blocking)
    planned = draft.kinds.map(&:key)
    dropped = draft.unusable_sections.select { |section| planned.include?(section.key) }
    finish_generation(user, language, draft, draft.problem_set,
                      dropped_concepts: dropped.to_h { |section| [ section.key, section.concept ] })
    JudgedSet.new(problem_set: draft.problem_set, dropped_sections: dropped.map(&:key), outcomes: {},
                  plan_notes: draft.plan.notes)
  end

  # JudgedGeneration owns the judge, retry and drop rules; each provider instance it uses is built fresh from this key.
  def generate_judged_exercise(user, language: user.language_for_today)
    draft = draft_exercise(user, language: language, blocking: false)
    JudgedGeneration.call(
      user: user, language: language, draft: draft,
      providers: -> { fresh_service.judged_generation_provider },
      finish: ->(set, **logs) { finish_generation(user, language, draft, set, **logs) }
    ).with(plan_notes: draft.plan.notes)
  end

  # Each thread has its own service and holds no DB connection during the HTTP call; a failed section is tagged, not raised.
  def review_sections(user, exercise, daily_response, sections:)
    # Started first so the extra provider call overlaps the grading instead of adding to the wait.
    difficulty = thread_in_caller_zone { safe_difficulty_assessment(user, exercise, sections) }

    translate_before_grading(user, exercise, daily_response, sections)

    coach   = config_for(exercise.language)[:coach]
    context = build_review_day_context(coach, exercise, daily_response)
    threads = sections.map { |section| thread_in_caller_zone { grade_section(user, exercise, daily_response, section, context) } }

    results = threads.map(&:value).to_h
    merge_difficulty!(results, awaited_difficulty(difficulty))
    results
  end

  # ── Generate the one-time cached reference for a single concept ───────────
  def generate_concept_reference(user, concept, language)
    config = config_for(language)

    result = call_and_log(
      user, purpose: "generate_concept_reference",
      system: "You are a senior #{config[:coach]} engineer writing a concise, durable reference for one concept. Return ONLY valid JSON.",
      prompt: build_concept_reference_prompt(concept, config),
      read_timeout: CONCEPT_REFERENCE_READ_TIMEOUT
    )

    reference = parse_json_object(result[:text], subject: "concept reference")

    # Cached by (concept, language) forever, so reject an unusable field and keep any existing reference for a retry.
    missing = CONCEPT_REFERENCE_FIELDS.reject { |field| reference[field].is_a?(String) && reference[field].strip.present? }
    if missing.any?
      raise InvalidResponseError, "Concept reference missing required field(s): #{missing.join(', ')}"
    end

    normalize_optional_reference_fields!(reference)

    reference
  end

  # Handed no exercise, response or history; see RECOGNITION_GUIDE_SCOPE.
  def generate_recognition_guide(user, group_key)
    result = call_and_log(
      user, purpose: "generate_recognition_guide",
      system: "You are a senior engineer writing a short, durable piece on how to recognize one category of problem. Return ONLY valid JSON.",
      prompt: build_recognition_guide_prompt(group_key),
      read_timeout: CONCEPT_REFERENCE_READ_TIMEOUT
    )

    guide = parse_json_object(result[:text], subject: "recognition guide")
    RECOGNITION_GUIDE_FIELDS.each { |field| guide[field] = usable_optional_text(guide[field], MAX_CONCEPT_GUIDE_LENGTH) }

    missing = RECOGNITION_GUIDE_FIELDS.select { |field| guide[field].nil? }
    raise InvalidResponseError, "Recognition guide missing usable field(s): #{missing.join(', ')}" if missing.any?

    guide.slice(*RECOGNITION_GUIDE_FIELDS)
  end

  # Reachable before submission, so it gets no exercise or answer; nothing is persisted (see ConceptReferencesController).
  def explain_concept_differently(user, reference, prior_alternates: [])
    # reference.language is a ConceptBucket, so this also resolves the language-independent buckets.
    coach = config_for(reference.language)[:coach]

    already_read = CONCEPT_REFERENCE_FIELDS
      .map { |field| "#{field}: #{reference.public_send(field)}" }
      .join("\n")

    result = call_and_log(
      user, purpose: "explain_concept_differently", max_tokens: CONCEPT_ALTERNATE_MAX_TOKENS,
      system: "You are a senior #{coach} engineer re-teaching one concept to an engineer for whom the standard reference did not land. Return plain prose — no JSON, no markdown fences.\n\n#{UserText::PROMPT_RULE}",
      prompt: <<~PROMPT
        The concept: "#{reference.concept}"

        The reference they have already read:
        #{already_read}

        #{prior_framings(prior_alternates)}

        #{self.class.explain_differently_standard("concept")}
        #{CONCEPT_REFERENCE_SCOPE} Teach the concept itself; never solve, hint at,
        or refer to any particular exercise. Two short paragraphs at most.

        #{PLAIN_LANGUAGE_STANDARD}
      PROMPT
    )

    text_or_raise(result, subject: "alternate concept explanation")
  end

  # Plain string, not JSON: there is nothing to parse, and parse_json_object would only add a failure mode.
  def explain_differently(user, exercise, daily_response, section:, prior_alternates: [])
    coach   = config_for(exercise.language)[:coach]
    review  = daily_response.ai_review&.dig(section) || {}
    missed  = DailyResponse.review_points(review["missed"])

    result = call_and_log(
      user, purpose: "explain_differently",
      system: "You are a senior #{coach} engineer re-explaining one point to an engineer who did not follow the first explanation. Return plain prose — no JSON, no markdown fences.\n\n#{UserText::PROMPT_RULE}",
      prompt: <<~PROMPT
        The engineer was asked: #{exercise.problem_set.dig(section, "question")}
        #{UserText.labelled("Their answer:", daily_response.answer_for(section))}

        What they missed:
        #{missed.any? ? missed.map { |m| "- #{m}" }.join("\n") : "- (nothing recorded)"}

        #{prior_framings(prior_alternates)}

        #{self.class.explain_differently_standard("point")}
        Two short paragraphs at most.

        #{PLAIN_LANGUAGE_STANDARD}
      PROMPT
    )

    text_or_raise(result, subject: "alternate explanation")
  end

  # `thread` holds the prior { role:, content: } turns for this section, sent to the provider as real turns.
  def answer_follow_up(user, exercise, daily_response, section:, question:, thread: [])
    coach  = config_for(exercise.language)[:coach]
    review = daily_response.ai_review&.dig(section) || {}

    review_summary = DailyResponse::AI_REVIEW_FIELDS.keys.filter_map { |key|
      points = DailyResponse.review_points(review[key])
      "#{DailyResponse.ai_review_label(key, locale: :en)}: #{points.join('; ')}" if points.any?
    }.join("\n")

    result = call_and_log(
      user, purpose: "review_follow_up",
      # The engineer's own answer stays in the user turn, since a role boundary the user can write across is no boundary.
      system: <<~SYSTEM,
        You are a senior #{coach} engineer answering a follow-up question about feedback you already gave. Return plain prose — no JSON, no markdown fences.

        #{UserText::PROMPT_RULE}

        #{PLAIN_LANGUAGE_STANDARD}

        The original exercise asked: #{exercise.problem_set.dig(section, "question")}

        The review you gave:
        #{review_summary.presence || "(no detail recorded)"}
      SYSTEM
      history: UserText.tag_history(thread, limit: UserText::MAX_QUESTION_LENGTH),
      prompt: <<~PROMPT
        #{UserText.labelled("Their answer was:", daily_response.answer_for(section))}

        #{UserText.labelled("Their new question:", question, blank: "(none asked)",
                            limit: UserText::MAX_QUESTION_LENGTH)}

        Answer it directly. Stay on this concept — if they drift far off topic, say
        so briefly and bring it back. Two short paragraphs at most.
      PROMPT
    )

    text_or_raise(result, subject: "follow-up answer")
  end

  # Fully unpersisted: `thread` is the client's in-memory conversation, sent back each request and never stored.
  def duck_response(user, exercise, section:, message:, thread: [])
    result = call_and_log(
      user, purpose: "duck_thread", max_tokens: DUCK_RESPONSE_MAX_TOKENS, allow_truncated: true,
      system: "#{DUCK_SYSTEM_PROMPT}\n\n#{UserText::PROMPT_RULE}\n\nThe exercise section:\n#{duck_section_context(exercise, section)}",
      # A bet that threads continue past one turn; CLAUDE.md's "Conversational calls send real turns" holds the numbers.
      cache_system: true,
      history: UserText.tag_history(thread),
      prompt: <<~PROMPT
        Their new message:
        #{UserText.tagged(message, blank: "(nothing said)")}

        Respond as their Socratic thinking partner, following your system instructions exactly.
      PROMPT
    )

    text = text_or_raise(result, subject: "duck response")
    result[:truncated] ? "#{text}…" : text
  end

  # `gaps_found` is a typed boolean because a malformed response also normalizes to an empty list.
  def critique_pseudocode(user, exercise, section:, pseudocode:)
    result = call_and_log(
      user, purpose: "pseudocode_critique", max_tokens: PSEUDOCODE_CRITIQUE_MAX_TOKENS,
      system: "#{PSEUDOCODE_CRITIQUE_SYSTEM_PROMPT}\n\n#{UserText::PROMPT_RULE}",
      prompt: build_pseudocode_critique_prompt(exercise, section, pseudocode)
    )

    parsed     = parse_json_object(result[:text], subject: "pseudocode critique", log_raw: false)
    gaps_found = parsed["gaps_found"]
    unless [ true, false ].include?(gaps_found)
      raise InvalidResponseError, "Pseudocode critique returned no usable \"gaps_found\" flag"
    end

    gaps = ExerciseSection::PseudocodeToCode.normalize_critique(parsed["gaps"])
    raise InvalidResponseError, "Pseudocode critique claimed gaps but returned none usable" if gaps_found && gaps.empty?

    log_pseudocode_critique(user, gaps_found, gaps)
    { gaps_found: gaps_found, gaps: gaps_found ? gaps : [] }
  end

  # Round 2: one call, always available, never gated on round 1's outcome.
  def translate_pseudocode(user, exercise, section:, pseudocode:)
    result = call_and_log(
      user, purpose: "pseudocode_translate",
      system: "#{PSEUDOCODE_TRANSLATE_SYSTEM_PROMPT}\n\n#{UserText::PROMPT_RULE}",
      prompt: build_pseudocode_translate_prompt(exercise, section, pseudocode)
    )

    # Normalized before measuring, since NFC can lengthen a string past UserText.tagged's cap downstream.
    code = UserText.normalize(text_or_raise(result, subject: "pseudocode translation"))
    # Rejected, never truncated: cut code no longer matches the plan it is graded as; raising keeps the round retryable.
    if code.length > MAX_GENERATED_CODE_LENGTH
      raise InvalidResponseError,
            "Pseudocode translation came back too long to be usable (#{code.length} characters)"
    end

    code
  end

  # Answer key and server stamps are stripped, since they say what the day intended; rung and lock arrive as arguments.
  def judge_section(user, kind, section, rung:, locked:)
    visible = section.except(*ExerciseSection.all_answer_key_fields, *ProblemSetIngest::SERVER_STAMPS)
    result  = call_and_log(
      user, purpose: "judge_section", max_tokens: JUDGE_MAX_TOKENS,
      response_schema: JudgeVerdict.schema_for(kind),
      system: JUDGE_SYSTEM_PROMPT,
      prompt: judge_prompt(kind, visible, rung: rung, locked: locked)
    )
    raw = parse_json_object(result[:text], subject: "#{kind.key} verdict", log_raw: kind.judge_solve_options.nil?)
    JudgeVerdict.parse(raw, kind: kind)
  end

  # Never handed the answer, problem or grading note, so the judge has nothing to regrade from.
  def judge_review_prose(user, kind, review, coach:)
    projection = ReviewProseVerdict.project(review)
    result = call_and_log(
      user, purpose: "judge_review", max_tokens: REVIEW_JUDGE_MAX_TOKENS,
      read_timeout: REVIEW_JUDGE_READ_TIMEOUT, single_attempt: true,
      response_schema: ReviewProseVerdict.schema,
      system: REVIEW_PROSE_JUDGE_SYSTEM_PROMPT,
      prompt: review_prose_prompt(kind, coach, projection)
    )
    raw = parse_json_object(result[:text], subject: "review prose verdict", log_raw: false)
    ReviewProseVerdict.parse(raw, projection: projection)
  end

  # A class method so JudgedGeneration names failures the same way this class does.
  def self.error_code_for(error)
    case error
    when AuthenticationError  then "authentication"
    when RateLimitError       then "rate_limit"
    when BillingError         then "out_of_credit"
    when TrialEndedError      then "trial_ended"
    when TrialAllowanceError  then "trial_allowance_used"
    when InvalidResponseError then "invalid_response"
    else                           "other"
    end
  end

  # Codes come from ApiUsage::FAILURES; a refusal or truncation is recorded on the row its billed tokens went to.
  def self.failure_code_for(error)
    case error
    when RateLimitError         then "rate_limit"
    when AuthenticationError    then "authentication"
    when BillingError           then "out_of_credit"
    when TimeoutError           then "timeout"
    when NetworkError           then "network"
    when TruncatedResponseError then "truncated"
    when InvalidResponseError   then "invalid_response"
    when RefusalError           then "refusal"
    else                             "provider_error"
    end
  end

  # One table for both judges so fallback rates compare; a code, never the message, which can carry provider text.
  def self.judge_fallback_reason(error)
    case error
    when JudgeVerdict::Invalid, ReviewProseVerdict::Invalid then "invalid_output"
    when TruncatedResponseError                              then "truncated"
    when InvalidResponseError                                then "invalid_json"
    when RefusalError                                        then "refusal"
    when TimeoutError, Timeout::Error                        then "timeout"
    else                                                          http_status_code_for(error) || error_code_for(error)
    end
  end

  # Only a plain Error: authentication and rate limits keep their own codes.
  def self.http_status_code_for(error)
    "http_#{error.http_status}" if error.instance_of?(Error) && error.http_status
  end

  protected

  # Bound methods, so neither call has to join this class's public API.
  def judged_generation_provider
    JudgedGeneration::Provider.new(judge_section: method(:judge_section), retry_section: method(:retry_section))
  end

  private

  def review_prose_prompt(kind, coach, projection)
    <<~PROMPT
      Section kind: #{kind.key}
      The review is written for an engineer working in #{coach}.
      Each list field is an array; an entry's index is its zero-based position.

      The review's prose:
      #{JSON.pretty_generate(projection)}
    PROMPT
  end

  def judge_prompt(kind, visible, rung:, locked:)
    <<~PROMPT
      Section kind: #{kind.key}
      The learner's task for this kind: #{kind.judge_task}
      #{kind.discovery? ? "This is a discovery task: wording that names where the issue is defeats it." : "Naming the concept is expected for this kind."}
      Tagged concept: #{visible["concept"]}
      Pitched at: #{rung}#{locked ? " (locked: this level was asked for unconditionally)" : ""}
      Level meaning: #{KindDifficulty::LEVEL_DEFINITIONS.fetch(rung)}
      Prose fields you may rewrite: #{kind.prose_fields.join(', ')}
      Every other field is the artifact and must not change.
      #{judge_guidance_block(kind)}
      The section as delivered:
      #{JSON.pretty_generate(visible)}
    PROMPT
  end

  # Stands in for the blank line above the section, so a kind with no guidance renders its usual prompt.
  def judge_guidance_block(kind)
    kind.judge_guidance ? "\n#{kind.judge_guidance}\n" : ""
  end

  # History is fetched once so the logged "requested" history can't diverge from what the prompt contained.
  def draft_exercise(user, language:, blocking:)
    plan       = DailyPlan.for(user, language: language)
    log_set_size(user, plan.size)
    history    = user.recent_performance
    difficulty = KindDifficulty.for(user)
    kinds      = ExerciseSection.for_plan(third: plan.third, fourth: plan.fourth, pattern: plan.pattern)
    ladders    = ladders_for(kinds, difficulty, language, plan.code_review_mode)
    options    = exercise_prompt_options(plan, history, difficulty, ladders)

    result = call_and_log(
      user, purpose: "generate_exercise",
      read_timeout: blocking ? SYNC_GENERATION_READ_TIMEOUT : GENERATION_READ_TIMEOUT,
      system: build_system_prompt(language),
      prompt: build_exercise_prompt(user, language, **options)
    )

    ingested = ProblemSetIngest.call(
      parse_json_object(result[:text], subject: "problem set", log_raw: false),
      language: language, expected_keys: kinds.map(&:key), code_review_source: plan.code_review_source,
      pitched_at: pitched_rungs(difficulty, user.skill_level), eased_for: eased_concepts_for(plan, difficulty)
    )

    log_unusable_sections(user, ingested.unusable_sections)
    Draft.new(problem_set: ingested.problem_set, plan: plan, kinds: kinds, difficulty: difficulty,
              ladders: ladders, history: history, prompt_options: options,
              suggested_concepts: ingested.suggested_concepts, unusable_sections: ingested.unusable_sections)
  end

  # The check's own message only: the section's text could carry its answer key.
  def log_unusable_sections(user, unusable)
    unusable.each do |section|
      Rails.logger.warn("[unusable_section] user=#{user.id} section=#{section.key} reason=#{section.reason}")
    end
  end

  def exercise_prompt_options(plan, history, difficulty, ladders)
    { third: plan.third, pattern: plan.pattern,
      reinforcement: plan.reinforcement, due_checks: plan.due_checks,
      established: plan.established, history: history,
      fourth: plan.fourth, fourth_reinforcement: plan.fourth_reinforcement,
      fourth_due_checks: plan.fourth_due_checks, fourth_established: plan.fourth_established,
      code_review_mode: plan.code_review_mode,
      code_review_source: plan.code_review_source,
      scenario_flavor: plan.scenario_flavor, shared_concept: plan.shared_concept,
      difficulty: difficulty, ladders: ladders }
  end

  # Over every kind: slot precedence can show a section the day didn't ask for.
  def pitched_rungs(difficulty, skill_level)
    ExerciseSection.all.to_h { |kind| [ kind.key, difficulty.rung_for(kind, skill_level: skill_level) ] }
  end

  # `draft` still holds every drafted section, so a dropped key can be named with its concept.
  def finish_generation(user, language, draft, set, dropped_concepts: {}, judge: nil, unhosted: [])
    plan = draft.plan
    # After ingest, which raises on an unusable set, so a rejected response cannot leave a suggestion behind.
    record_suggested_concepts(draft.suggested_concepts)

    fourth_dropped, language_dropped = dropped_concepts
      .partition { |key, _| ExerciseSection.fourths.include?(ExerciseSection.find(key)) }.map(&:to_h)
    log_retention(user, language, plan.due_checks, set, plan.code_review_mode, dropped: language_dropped)
    if plan.fourth
      log_retention(user, DailyPlan::FOURTH_BUCKET_FOR.fetch(plan.fourth), plan.fourth_due_checks,
                    set, plan.code_review_mode, dropped: fourth_dropped)
    end
    log_waiting_retention(user, plan.waiting_checks)
    log_shared_concept(user, plan.shared_concept, set)
    log_coverage(user, plan.coverage)
    log_difficulty_diagnostics(user, language, plan, set, draft.history,
                               kinds: draft.kinds, difficulty: draft.difficulty, ladders: draft.ladders,
                               judge: judge, unhosted: unhosted)
  end

  # Raises on failure; JudgedGeneration decides what a failed retry means.
  def retry_section(user, language, draft, kind, concept)
    result = call_and_log(
      user, purpose: "retry_section", read_timeout: RETRY_READ_TIMEOUT,
      system: build_system_prompt(language),
      prompt: build_exercise_prompt(user, language, **draft.prompt_options, only: kind, fixed_concept: concept)
    )

    ProblemSetIngest.call(
      parse_json_object(result[:text], subject: "#{kind.key} retry", log_raw: false), language: language,
      expected_keys: [ kind.key ], fixed_concepts: { kind.key => concept },
      code_review_source: draft.plan.code_review_source,
      pitched_at: { kind.key => draft.difficulty.rung_for(kind, skill_level: user.skill_level) },
      eased_for: eased_concepts_for(draft.plan, draft.difficulty).slice(kind.key)
    ).problem_set[kind.key]
  end

  # Optional fields are rendered into pages and prompts, so anything but a bounded String becomes nil instead of raising.
  def normalize_optional_reference_fields!(reference)
    CONCEPT_GUIDE_FIELDS.each { |field| reference[field] = usable_optional_text(reference[field], MAX_CONCEPT_GUIDE_LENGTH) }
    CONCEPT_LADDER_FIELDS.each { |field| reference[field] = usable_optional_text(reference[field], MAX_LADDER_RUNG_LENGTH) }
    reference["lesson"] = ConceptLesson.from_provider(reference["lesson"])
  end

  def usable_optional_text(value, max_length)
    text = value.is_a?(String) ? value.strip : nil

    text.blank? || text.length > max_length ? nil : text
  end

  # The fold's wording lives here with the other prompt text; a subclass decides only whether to fold (GeminiService#call).
  def flatten_history(history, prompt)
    return prompt if history.empty?

    "Conversation so far:\n#{render_thread(history)}\n\n#{prompt}"
  end

  def render_thread(thread)
    thread.map { |turn| "#{turn[:role] == "assistant" ? "You" : "Them"}: #{turn[:content]}" }.join("\n")
  end

  # The one view of a section as the engineer sees it, for the duck and the difficulty prompt; never add answer-key fields.
  def duck_section_context(exercise, section)
    data = exercise.problem_set.dig(section.to_s) || {}

    [
      ("Title: #{data["title"]}" if data["title"].present?),
      ("Scenario: #{data["scenario"]}" if data["scenario"].present?),
      ("Why it exists: #{data["why"]}" if data["why"].present?),
      ("Question: #{data["question"]}" if data["question"].present?),
      ("Options: #{Array(data["options"]).join(" / ")}" if data["options"].present?),
      ("Code snippet:\n#{data["snippet"]}" if data["snippet"].present?),
      ("Current schema, as the table stands today:\n#{data["current_schema"]}" if data["current_schema"].present?),
      ("Starter code:\n#{data["starter_code"]}" if data["starter_code"].present?),
      ("Plan excerpt:\n#{data["plan_excerpt"]}" if data["plan_excerpt"].present?),
      ("The problem to plan:\n#{data["problem_statement"]}" if data["problem_statement"].present?),
      ("Feature request:\n#{data["request"]}" if data["request"].present?),
      ("Piece A:\n#{data["piece_a"]}" if data["piece_a"].present?),
      ("Piece B:\n#{data["piece_b"]}" if data["piece_b"].present?),
      duck_parsons_blocks(data)
    ].compact.join("\n")
  end

  # Stored blocks are already solved, so positions come only from a persisted scramble; otherwise blocks go unordered.
  def duck_parsons_blocks(data)
    blocks = data["blocks"]
    return unless blocks.is_a?(Array) && blocks.any?

    order = scrambled_display_order(data["display_order"], blocks.size)
    # to_s first: a provider can return non-strings, and sorting mixed types raises.
    return "Blocks (order withheld):\n#{blocks.map(&:to_s).sort.map { |b| "- #{b}" }.join("\n")}" unless order

    lines = order.map.with_index { |block_index, position| "#{position + 1}. #{blocks[block_index]}" }
    "Blocks, in the learner's current on-screen order (NOT the correct order):\n#{lines.join("\n")}"
  end

  # The identity permutation means no scramble was persisted; echoing it would present the solution as the learner's order.
  def scrambled_display_order(display_order, block_count)
    order = ExerciseSection::ParsonsProblem.normalize_order(Array(display_order), block_count)
    return if order.empty? || order == (0...block_count).to_a

    order
  end

  def build_pseudocode_critique_prompt(exercise, section, pseudocode)
    data = exercise.problem_set[section.to_s] || {}

    <<~PROMPT
      The problem they are planning:
      #{data["problem_statement"]}

      Their pseudocode:
      #{UserText.tagged(pseudocode)}

      Apply your standard exactly as stated in your system instructions:
      #{ExerciseSection::PseudocodeToCode.gap_standard}
    PROMPT
  end

  def build_pseudocode_translate_prompt(exercise, section, pseudocode)
    data = exercise.problem_set[section.to_s] || {}

    <<~PROMPT
      Target language: #{config_for(exercise.language)[:label]}.

      The problem they were planning, for naming only — never for filling gaps:
      #{data["problem_statement"]}

      Their pseudocode, to transcribe literally:
      #{UserText.tagged(pseudocode)}
    PROMPT
  end

  # Counts and flags only; pairs with ResponsesController#log_pseudocode_review_diagnostics by user id and date.
  def log_pseudocode_critique(user, gaps_found, gaps)
    Rails.logger.info(
      "[pseudocode] user=#{user.id} date=#{Date.current} phase=critique " \
      "gaps_found=#{gaps_found} gaps=#{gaps.size}"
    )
  end

  # Each framing is fenced because the page sends them back, so a forged one is a request away.
  def prior_framings(prior_alternates)
    return "No alternate framing has been given yet." if prior_alternates.empty?

    "Framings already given (do NOT reprise these angles or analogies):\n" +
      prior_alternates.map.with_index(1) { |a, i| "#{i}. #{UserText.tagged(a, blank: '')}" }.join("\n")
  end

  # A blank response would fail a validation outside `rescue AiService::Error` and give the user a raw 500.
  def text_or_raise(result, subject:)
    text = result[:text].to_s.strip
    raise InvalidResponseError, "Provider returned an empty #{subject}" if text.blank?
    text
  end

  def error_code_for(error) = self.class.error_code_for(error)

  # Fails loudly on "mixed" or a typo instead of silently falling back to Ruby/Rails.
  def config_for(language)
    LANGUAGE_CONFIG.fetch(language) do
      raise Error, "Unsupported generation language: #{language.inspect}"
    end
  end

  # Names the sections that can host the concept today; otherwise the model guesses and ingest records a false miss.
  def annotate_retention_concept(cm, kinds, language, code_review_mode, rungs)
    hosts = kinds.filter_map do |kind|
      mode = code_review_mode if kind == ExerciseSection::CodeReview
      kind.key if can_host?(cm, kind.key, language, mode: mode, rung: rungs[kind])
    end

    # nil when no section today can host the concept; the caller drops it from the prompt.
    return nil if hosts.empty?

    "#{cm.concept} (#{hosts.to_sentence(two_words_connector: ' or ', last_word_connector: ', or ')})"
  end

  # Use the day's language, not cm.language: LANGUAGE_CONFIG's "architecture" entry would report false hosts.
  def can_host?(cm, section_key, language, mode: nil, rung: nil)
    ProblemSetIngest.selectable_vocabulary_for(section_key, language, mode: mode, rung: rung).include?(cm.concept)
  end

  # Logged after ingest, over the delivered set, so a check the judge dropped reads as offered and not honored.
  def log_retention(user, bucket, due_checks, problem_set, code_review_mode, dropped: {})
    return if due_checks.empty?

    offered = due_checks.map(&:concept)
    tagged  = problem_set.values.filter_map { |s| s["concept"] if s.is_a?(Hash) }
    honored = offered & tagged

    Rails.logger.info(
      "[retention] user=#{user.id} date=#{Date.current} bucket=#{bucket} " \
      "code_review_mode=#{code_review_mode} " \
      "offered=#{offered.join(',').presence || '-'} " \
      "honored=#{honored.join(',').presence || '-'} " \
      "tagged=#{tagged.join(',').presence || '-'} " \
      "dropped=#{dropped.map { |key, concept| "#{key}:#{concept}" }.join(',').presence || '-'}"
    )
  end

  # Logged before the provider is contacted, so an attempt that later fails still leaves its size behind.
  def log_set_size(user, size)
    Rails.logger.info("[set_size] user=#{user.id} date=#{Date.current} #{size.diagnostics.to_json}")

    previous = user.daily_exercises.planned_size_before(Date.current)
    return if previous.nil? || previous == size.count

    Rails.logger.info("[set_size] user=#{user.id} from=#{previous} to=#{size.count} reason=#{size.reason}")
  end

  def log_coverage(user, coverage)
    return if coverage.nil?

    Rails.logger.info("[coverage] user=#{user.id} kind=#{coverage.kind.key} reason=#{coverage.reason}")
  end

  # The pairing is advisory, so whether the model placed it is read from the delivered set.
  def log_shared_concept(user, concept, problem_set)
    return if concept.nil?

    Rails.logger.info(
      "[shared_concept] user=#{user.id} concept=#{concept} reason=reduced_tier " \
      "honored=#{ExerciseSection.fixed_sections_share?(problem_set, concept)}"
    )
  end

  # Otherwise checks the plan did not offer would stay due with no trace.
  def log_waiting_retention(user, waiting)
    return if waiting.empty?

    entries = waiting.map { |check| "#{check[:bucket]}:#{check[:concept]}(#{check[:reason]})" }
    Rails.logger.info("[retention] user=#{user.id} date=#{Date.current} waiting=#{entries.join(',')}")
  end

  # Difficulty adaptation is advisory; this pairs requested with delivered to check it, alongside log_review_diagnostics.
  def log_difficulty_diagnostics(user, language, plan, problem_set, history, kinds:, difficulty:, ladders:,
                                 judge: nil, unhosted: [])
    requested = {
      skill_level: user.skill_level,
      code_review_mode: plan.code_review_mode,
      code_review_source: plan.code_review_source&.id,
      scenario_flavor: plan.scenario_flavor,
      pattern: plan.pattern,
      third: plan.third,
      fourth: plan.fourth,
      section_count: kinds.size,
      reinforcement: plan.reinforcement,
      due_checks: plan.due_checks.map(&:concept),
      established: plan.established.map(&:concept),
      shared_concept: plan.shared_concept,
      coverage: plan.coverage && { kind: plan.coverage.kind.key, reason: plan.coverage.reason },
      size: plan.size.diagnostics,
      recent_performance: history
    }
    requested.merge!(kind_difficulty_diagnostics(kinds, difficulty, ladders, language, plan.code_review_mode, problem_set))

    payload = {
      event: "generation",
      user_id: user.id,
      date: Date.current.to_s,
      language: language,
      requested: requested,
      delivered: without_answer_key(problem_set),
      judge: judge,
      unhosted: unhosted
    }

    Rails.logger.info("[difficulty_diagnostics] #{payload.to_json}")
  end

  # Shows the tier and `drilled` side by side so a log line can tell the system's reading from the engineer's request.
  def annotate_reinforcement(entry)
    "#{entry[:concept]} (#{[ entry[:tier], ("drilled" if entry[:drilled]) ].compact.join(', ')})"
  end

  # The one easing the server decides; locked kinds are exempt, and the model's rating adjustments can't be recorded here.
  def eased_concepts_for(plan, difficulty)
    reduced_main   = reduced_concepts(plan.reinforcement)
    reduced_fourth = reduced_concepts(plan.fourth_reinforcement)

    ExerciseSection.all.reject { |kind| difficulty.locked?(kind) }.to_h do |kind|
      [ kind.key, kind.fourth? ? reduced_fourth : reduced_main ]
    end
  end

  def reduced_concepts(entries)
    entries.select { |h| h[:tier] == "reduced" }.map { |h| h[:concept] }
  end

  # Measures whether a rung was available and chosen; whether the problem was pitched at it is deliberately not measured.
  def kind_difficulty_diagnostics(kinds, difficulty, ladders, language, mode, problem_set)
    targeted = kinds & difficulty.targeted_kinds
    return {} if targeted.empty?

    per_kind = targeted.to_h do |kind|
      vocabulary = ProblemSetIngest.selectable_vocabulary_for(kind.key, language, mode: mode, rung: difficulty.level_for(kind))
      grounded   = vocabulary & ladders.fetch(difficulty.level_for(kind), {}).keys
      chosen     = problem_set.dig(kind.key, "concept")
      [ kind.key, { level: difficulty.level_for(kind), locked: difficulty.locked?(kind),
                    ladder_coverage: "#{grounded.size}/#{vocabulary.size}",
                    chosen_concept: chosen, chosen_grounded: grounded.include?(chosen) } ]
    end

    { kind_difficulty: per_kind, kind_difficulty_chars: kind_difficulty_guidance(kinds, difficulty, ladders).length }
  end

  # The only whole-payload serializer, so the answer-key exclusion lives here; returns a copy, since the caller persists it.
  def without_answer_key(problem_set)
    problem_set.transform_values do |section|
      section.is_a?(Hash) ? section.except(*ExerciseSection.all_answer_key_fields) : section
    end
  end

  # Abstract: returns { text:, input_tokens:, output_tokens: }; `history` is prior turns and `prompt` the new user turn.
  def call(system:, prompt:, cache_system: false, read_timeout: READ_TIMEOUT, max_tokens: nil, history: [], purpose: nil, response_schema: nil, single_attempt: false)
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

      #{UserText::PROMPT_RULE}
    PROMPT
  end

  # Each kind owns its schema fragment; this joins the fragments for today's kinds.
  def exercise_schema_for(language = "ruby_rails", third: :challenge, fourth: :plan_review, pattern: :pattern, only: nil)
    label = config_for(language)[:label]

    kinds = only ? [ only ] : ExerciseSection.for_plan(third: third, fourth: fourth, pattern: pattern)
    sections = kinds.map { |kind| kind.schema_fragment(label: label) }
                    .join(",\n  ")

    <<~SCHEMA
      {
        #{sections}
      }
    SCHEMA
  end

  # #generate_exercise passes its own history so the prompt and diagnostics log see the same snapshot.
  def build_exercise_prompt(user, language = "ruby_rails", third: :challenge, pattern: :pattern,
                            reinforcement: nil, due_checks: [],
                            established: [], history: user.recent_performance,
                            fourth: :plan_review, fourth_reinforcement: [], fourth_due_checks: [], fourth_established: [],
                            code_review_mode: :application_code, code_review_source: nil,
                            scenario_flavor: :general, shared_concept: nil,
                            difficulty: KindDifficulty.none, ladders: {},
                            only: nil, fixed_concept: nil)
    history_text = if history.empty?
      "No history yet — this is their first exercise set."
    else
      history.map { |h|
        pairs = h[:concepts].respond_to?(:each_pair) ? h[:concepts].each_pair.filter_map { |section, concept|
          next if concept.blank?
          self_r  = h[:self_ratings][section].presence || "unrated"
          skipped = h[:answered_sections] && !h[:answered_sections].include?(section)
          ai_r    = skipped ? "skipped" : (h[:ai_ratings][section].presence || "unreviewed")
          "#{section}→#{concept} (self: #{self_r}, ai: #{ai_r})"
        } : []
        concept_text = pairs.any? ? " | #{pairs.join(', ')}" : ""
        framings     = h[:scenarios].presence || []
        framing_text = framings.any? ? " | framings: #{framings.join('; ')}" : ""
        "#{h[:date]}: #{h[:sections_answered]}/#{h[:sections_total]} answered#{concept_text}#{framing_text}"
      }.join("\n")
    end

    # Direct callers only; #generate_exercise passes the plan's list, which applies the per-section hosting test for drills.
    reinforcement_list = reinforcement || user.concepts_needing_reinforcement(exclude_buckets: DailyPlan::FOURTH_BUCKETS)
    reinforcement_text = reinforcement_list.any? ?
      reinforcement_list.map { |h| annotate_reinforcement(h) }.join(", ") : "none"

    # Resolved once through the schema's call, so guidance, hosting and schema agree; `only` narrows to one retried kind.
    kinds = only ? [ only ] : ExerciseSection.for_plan(third: third, fourth: fourth, pattern: pattern)

    # filter_map: a due concept no section can host annotates as nil and is dropped from the prompt.
    rungs = kinds.index_with { |kind| difficulty.rung_for(kind, skill_level: user.skill_level) }
    annotated_due_checks = due_checks.filter_map { |cm| annotate_retention_concept(cm, kinds, language, code_review_mode, rungs) }

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

    # Unlike retention_block, this never forces a selection.
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
      fourth_reinforcement.map { |h| annotate_reinforcement(h) }.join(", ") : "none"

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

    # Folded onto the drilled-concepts bullet: an empty interpolation on its own line would break the prompt snapshots.
    fixed_concept_line = fixed_concept ?
      "\n- This section's concept must be exactly `#{fixed_concept}`: it replaces a section that was rejected on wording alone, and the day's plan already placed this concept here." :
      ""
    shared_concept_line = only ? "" : shared_concept_guidance(shared_concept)

    config = config_for(language)
    label  = config[:label]
    focus  = user.focus_areas.any? ? user.focus_areas.join(", ") : "general #{label} patterns"

    # Keyed off the same `kinds` as the schema, so guidance can't disagree with what the schema asks for.
    sections_guidance = kinds.map { |kind|
      mode = code_review_mode if kind == ExerciseSection::CodeReview
      generation_guidance_for(kind, language, mode: mode, source: code_review_source, rung: rungs[kind])
    }.join("\n")

    <<~PROMPT
      Generate a daily Code Gym exercise set for this engineer.

      Engineer profile:
      - Name: #{UserText.tagged(user.name, blank: "(not given)", inline: true,
                                limit: UserText::MAX_NAME_LENGTH)}
      - Skill level: #{user.skill_level} (#{User::SKILL_LEVELS.join(" → ")})
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
      #{scenario_flavor_guidance(scenario_flavor)}
      - Each teaching_note must point toward how to think about the problem or the right question to ask — one or two sentences, never the full answer.
      - answer_scaffold (#{scaffolded_kinds_clause} only): #{ExerciseSection::MAX_SCAFFOLD_LABELS} labels at most, #{ExerciseSection::MAX_SCAFFOLD_LABEL_LENGTH} characters at most each, ending in a colon. These pre-fill the answer box, so write them for THIS question specifically — name the parts a complete answer to it must cover, in the order someone should think them through (e.g. for a caching decision: "Which option, and why:", "How you'd handle a stale entry:"). Generic prompts that would fit any question of this kind are a wasted scaffold. Each is a heading the engineer writes UNDER, so it must ask for something, never state or hint at the answer — the teaching_note rules apply here too.
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
      #{silent_correctness_guidance}
      #{domain_modeling_guidance}
      - Reduced-tier concepts: for any concept whose annotation includes `reduced` (alone or as `(reduced, drilled)`), keep the SAME concept and vocabulary — never silently swap in a different, easier concept. Ease the difficulty only: simpler framing, a smaller scenario, more scaffolding/starter code, and a teaching_note that guides more directly toward the key insight (it may name the technique, but not the full answer).
      - Mastery loop: reintroduce every concept listed as "needing reinforcement right now" above (both standard and reduced tiers) with a fresh code example and framing — never a repeat snippet. A concept exits reinforcement only on full mastery: the user's self-rating for that section was "right level"/"too easy" AND the AI rated it "solid"/"strong". Short of that, steady improvement (a better AI rating than last time) still counts as progress — keep reinforcing, and let the tier annotation tell you how hard to pitch it.
      - Drilled concepts: a concept marked `drilled` is one the engineer asked to practise on purpose, not one the ratings flagged. Include it exactly as you would any other concept needing reinforcement, with fresh framing. Its difficulty comes only from its tier annotation and the section's level — `drilled` on its own never eases or raises anything.#{fixed_concept_line}#{shared_concept_line}
      #{retention_block}
      #{established_block}
      #{fourth_retention_block}
      #{fourth_established_block}#{kind_difficulty_guidance(kinds, difficulty, ladders)}
      - Concepts most recently rated "too easy" must not repeat within the same week.
      - Concepts most recently rated "right level" have no special weighting.

      Return JSON matching this schema exactly:
      #{exercise_schema_for(language, third: third, fourth: fourth, pattern: pattern, only: only)}
    PROMPT
  end

  # Folded onto the drilled-concepts bullet so a day without a pairing renders the prompt byte for byte as before.
  def shared_concept_guidance(concept)
    return "" if concept.nil?

    sections = ExerciseSection.fixed.map(&:key).to_sentence
    "\n- The #{sections} sections share `#{concept}` as their concept today. It is one concept needing reinforcement, looked at from different sides: each section tests it in its own way and its own scenario, following its own rules above."
  end

  # SCENARIO_POOLS.fetch, so an unknown flavor fails here instead of rendering an empty list.
  def scenario_flavor_guidance(flavor)
    pool    = SCENARIO_POOLS.fetch(flavor)
    flavors = (pool[:domains] - %w[legacy_graphql_maintenance]).map { |d| d.tr("_", " ") }.join(", ")

    [
      "- Prefer drawing each section's business-domain scenario from #{pool[:intro]} like: #{flavors} " \
        "(adapt any flavor to fit the day's stack — e.g. #{pool[:adaptation]}).",
      pool[:rule],
      pool[:legacy]
    ].compact.join(" ")
  end

  # Defers to each section's own vocabulary because ingest validates against the full one and would not catch a misuse.
  def data_modeling_idiom_guidance
    "- The data-modeling concepts (#{DATA_MODELING_CONCEPTS.join(', ')}) may be tagged on any section whose own " \
      "vocabulary list above includes them. " \
      "Only a schema-review code_review presents a schema artifact to review — anywhere else, express the " \
      "concept in that section's own idiom: a pattern question about wrong_cardinality asks how the " \
      "relationship should be modeled and what the wrong shape costs the code that uses it, not for a " \
      "migration to review; a design_comparison shows two ways to store or query the same data that behave the " \
      "same, such as with and without an index, and asks which one the stated access pattern should use."
  end

  # Confined to framing because code_review and challenge need a planted issue to grade "missed" against.
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
      "section's own idiom: on a test-file code_review, a god_object is a bloated test class; a " \
      "design_comparison shows one piece with the smell and one without it, behaving the same, and the " \
      "scenario states how the code changes, which decides what the smell costs. The challenge " \
      "section is the exception to the answer shape, since its answer is code: there the exercise is a " \
      "refactor — starter_code exhibits the smell at that scale and the question asks the engineer to " \
      "restructure it, so writing the better shape IS the answer rather than describing it."
  end

  # The principle frames the question and never replaces the findable issue, as with meta_skill_framing_guidance.
  def oo_design_violation_guidance
    "- The OO design-principle concepts (#{OO_DESIGN_CONCEPTS.join(', ')}) name a rule the code breaks, not a " \
      "topic to discuss. A section tagged with one must contain exactly one specific, findable violation of that " \
      "rule and be gradeable against it, and the answer is naming the violation and saying which future change it " \
      "makes hard, rather than a rewrite of the class. Express it in the host section's own idiom: a code_review " \
      "tagged open_closed shows a conditional that must be edited every time a variant is added; a pattern, which " \
      "shows no code, describes a hierarchy built for reuse and asks what the composed shape would be and what it " \
      "costs; a design_comparison shows one piece that follows the principle and one that breaks it, behaving " \
      "the same, and the scenario states the change that makes the difference matter; " \
      "on a test-file code_review the planted test smell must BE the violation rather than sit beside it, " \
      "which every principle in the group can express — a dependency_inversion violation is a test that can only " \
      "reach its subject by stubbing one hard-coded collaborator, an open_closed violation is a conditional " \
      "inside the test that gains a branch for every case added, and a composition_over_inheritance violation is " \
      "a test-case base class whose subclasses inherit setup they do not use. " \
      "The challenge section is the exception to the answer shape, since its answer is code: there the " \
      "starter_code violates the principle — a behavior that cannot be tested without reaching through a " \
      "hard-coded collaborator, for dependency_inversion — and the question asks for the version that satisfies " \
      "it, so writing the corrected design IS the answer rather than describing it."
  end

  # Interface depth can leave nothing missable, so like the other group rules this keeps a findable issue in the section.
  def module_design_depth_guidance
    "- The module-design concepts (#{MODULE_DESIGN_CONCEPTS.join(', ')}) name what a module's interface costs " \
      "every caller, not a bug in what it computes. A section tagged with one must contain exactly one specific, " \
      "findable instance of that shape and be gradeable against it, and the answer is naming the instance and " \
      "saying which future change its interface makes expensive, rather than a rewrite of the module. Express it " \
      "in the host section's own idiom: a code_review tagged pass_through_method shows a method whose entire body " \
      "forwards its arguments to one collaborator; on a test-file code_review, a shallow_module is a test helper " \
      "whose setup arguments spell out the very state it claims to hide; a pattern, which shows no code, " \
      "describes a module's interface and asks what it actually hides and what it forces every caller to know " \
      "anyway; a design_comparison shows a deep and a shallow version of the same interface, behaving the " \
      "same, and the scenario states how callers use it. The challenge section is " \
      "the exception to the answer shape, since its answer is code: there the starter_code exhibits the shape — " \
      "for temporal_decomposition, a flow split into objects that exist only because they run in that order — and " \
      "the question asks for the version organized around information instead, so writing the deeper module IS " \
      "the answer rather than describing it."
  end

  # Opposite risk to the other groups: the planted code must look like it works, or the concept is no longer what it names.
  def silent_correctness_guidance
    "- The silent-correctness concepts (#{SILENT_CORRECTNESS_CONCEPTS.join(', ')}) name a broken invariant that " \
      "looks like a working result. A section tagged with one must show code that runs clean — no exception, no " \
      "type or schema error, nothing a passing test would catch — and still produce a wrong answer, and the " \
      "engineer's job is to say which invariant it breaks and on what input. Calibrate to one specific defect at " \
      "this severity: an allocation_rounding split whose parts don't sum back to the total, or one that " \
      "distributes an input its own scenario makes meaningless — no buckets to split across, or a negative total " \
      "in a domain where only positive quantities exist — instead of rejecting it; a semantic_input_validation " \
      "boundary where an unrecognized unit falls through a lookup default and is stored as the canonical one, " \
      "right type and plausible magnitude, wrong meaning; a cache_key_completeness key naming one of the two " \
      "dimensions its value varies on, so every other request reads the first one cached; a " \
      "deterministic_ordering sort or comparator with no secondary key, so re-running the same query or " \
      "re-sorting the same list returns tied entries in a different order and a paginated pass repeats or skips " \
      "them. Two neighbours to stay clear of: cache_key_completeness is about the key's correctness, never about " \
      "whether to cache at all — that is the caching concept — and semantic_input_validation is about a value " \
      "whose meaning is wrong, never about one that is absent or malformed, which is validations. Express it in " \
      "the host section's own idiom: a pattern, which shows no code, describes the computation and asks which " \
      "inputs the result actually varies on and what the missing one costs; on a test-file code_review the " \
      "planted test smell must BE the silent defect rather than sit beside it — a test whose expected value is " \
      "computed the same wrong way as the subject, so it passes and proves nothing. The challenge section is the " \
      "exception to the answer shape, since its answer is code: there starter_code carries the defect and the " \
      "question asks for the version that holds the invariant, so writing the correct distribution, key, or " \
      "ordering IS the answer."
  end

  # Judgments about the model can leave nothing missable, so like the other group rules this keeps a findable issue.
  def domain_modeling_guidance
    "- The domain-modeling concepts (#{DOMAIN_MODELING_CONCEPTS.join(', ')}) name what the model calls things and " \
      "which things must change together, not a defect in what the code computes. A section tagged with one must " \
      "contain exactly one specific, findable instance and be gradeable against it, and the answer is naming the " \
      "instance and saying which future change it makes wrong or expensive, rather than a rewrite of the model. " \
      "For ubiquitous_language the scenario must establish the domain's own word before the code contradicts it — " \
      "a stated booking process whose model is called Order, or one word covering two different things — and the " \
      "code must otherwise do exactly what its names claim, which is what keeps this apart from reading_for_intent " \
      "(code diverging from its evident purpose) and from primitive_obsession (a missing type, not a wrong word). " \
      "For aggregate_boundaries plant one write path that leaves two rows disagreeing because no single object " \
      "owns the set, or a caller reaching past the owner to update a member directly; it is never about whether a " \
      "transaction was opened, which is transaction_safety, nor about which service owns the data, which is " \
      "data_ownership. Express it in the host section's own idiom: a pattern, which shows no code, describes the " \
      "model in the domain's words and asks which name is overloaded or which writes must not be separable; a " \
      "design_comparison shows two models with the same behavior, only one named or bounded the way the stated " \
      "domain is; on a " \
      "test-file code_review the planted test smell must BE the instance rather than sit beside it — a test whose " \
      "own setup names the same thing two ways, or one that builds a member row the aggregate's rules forbid on " \
      "its own. The challenge section is the exception to the answer shape, since its answer is code: there " \
      "starter_code carries the instance and the question asks for the renamed or re-bounded version, so writing " \
      "it IS the answer rather than describing it."
  end

  # Merging by concept name is safe because a day's buckets never share one (concept_reference_spec holds that).
  def ladders_for(kinds, difficulty, language, code_review_mode)
    targeted = kinds & difficulty.targeted_kinds
    return {} if targeted.empty?

    requests = targeted.map do |kind|
      { level: difficulty.level_for(kind), bucket: ConceptBucket.for(kind.key, language),
        concepts: ProblemSetIngest.selectable_vocabulary_for(kind.key, language, mode: code_review_mode,
                                                             rung: difficulty.level_for(kind)) }
    end
    pairs = requests.flat_map { |request| request[:concepts].map { |concept| [ request[:bucket], concept ] } }.uniq

    references = ConceptReference.where(language: pairs.map(&:first).uniq, concept: pairs.map(&:last).uniq)
                                 .select(&:ladder?)
                                 .index_by { |reference| [ reference.language, reference.concept ] }

    requests.each_with_object({}) do |request, ladders|
      field = LADDER_FIELD_FOR.fetch(request[:level])
      rungs = request[:concepts].filter_map do |concept|
        reference = references[[ request[:bucket], concept ]]
        [ concept, reference.public_send(field).truncate(MAX_LADDER_RUNG_LENGTH) ] if reference
      end.to_h
      (ladders[request[:level]] ||= {}).merge!(rungs)
    end
  end

  # Empty when nothing on today's plan is targeted, which keeps every other prompt byte-identical.
  def kind_difficulty_guidance(kinds, difficulty, ladders)
    targeted = kinds & difficulty.targeted_kinds
    return "" if targeted.empty?

    locked, unlocked = targeted.partition { |kind| difficulty.locked?(kind) }
    paragraphs = KindDifficulty::LEVELS.filter_map do |level|
      at_level = targeted.select { |kind| difficulty.level_for(kind) == level }
      level_difficulty_paragraph(level, at_level, ladders.fetch(level, {})) if at_level.any?
    end

    [ "", "Difficulty targets. For each section named below, its level replaces the skill level in the " \
          "engineer profile above, for that section only.",
      *paragraphs, "",
      "A retention check or established concept placed in one of these sections is pitched at that " \
      "section's level, with no easing.",
      unlocked_difficulty_line(unlocked), locked_difficulty_line(locked) ].compact.join("\n")
  end

  def level_difficulty_paragraph(level, kinds, rungs)
    definition = KindDifficulty::LEVEL_DEFINITIONS.fetch(level)
    lines = [ "", "Sections at #{level}: #{kinds.map(&:key).join(', ')}" ]
    return (lines << "Pitch these problems at this level. A #{level} problem is: #{definition}").join("\n") if rungs.empty?

    lines << "Pitch these problems at this level for whichever concept you choose:"
    lines.concat(rungs.sort.map { |concept, rung| "- #{concept}: #{rung}" })
    (lines << "For a concept not listed, a #{level} problem is: #{definition}").join("\n")
  end

  def unlocked_difficulty_line(kinds)
    return if kinds.empty?

    "Unlocked (#{kinds.map(&:key).join(', ')}): tier annotations and rating adjustments above still apply to " \
      "these sections, eased or raised from the section's level rather than from the profile's skill level."
  end

  # An easing rule added to the prompt later must be added here on purpose; nothing covers it by implication.
  def locked_difficulty_line(kinds)
    return if kinds.empty?

    "Locked (#{kinds.map(&:key).join(', ')}): for these sections, ignore the `(reduced)` easing rule and both " \
      "the \"too easy\" and \"too hard\" rating adjustments above, whichever concept they carry — including a " \
      "concept the engineer has never seen. Where a locked section has an answer scaffold or starter code, " \
      "write it at its level, not easier."
  end

  # From the registry, since a scaffolding kind left out of a written list gets its labels truncated mid-word (issue #164).
  def scaffolded_kinds_clause
    ExerciseSection.all.select(&:scaffolded?).map(&:key).to_sentence(last_word_connector: " and ")
  end

  # No branch on kind; each kind reads what it needs from the shared context (ExerciseSection.generation_guidance).
  def generation_guidance_for(kind, language, mode: nil, source: nil, rung: nil)
    config = config_for(language)

    kind.generation_guidance(
      vocabulary:     ProblemSetIngest.selectable_vocabulary_for(kind.key, language, mode: mode, rung: rung),
      label:          config[:label],
      mode:           mode,
      artifact:       config[:schema_artifact],
      test_framework: config[:test_framework],
      source:         source,
      rung:           rung
    )
  end

  def build_review_day_context(coach, exercise, daily_response)
    keys    = exercise.active_section_keys
    ratings = daily_response.section_ratings

    # "rounds" goes to every key so the assembler needn't branch on which kind reads it.
    sections = keys.map do |key|
      ExerciseSection.for(key).review_context(
        section: (exercise.problem_set[key] || {}).merge("rounds" => daily_response.pseudocode_round(key)),
        answer: daily_response.answer_for(key), rating: ratings[key]
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
      You are a senior #{coach} engineer giving direct, specific feedback on an engineer's Code Gym answers. You will grade exactly one of the day's #{keys.size} sections in a follow-up instruction — #{others_clause} given here only as context, since each section is rated against its own pitched level. Be honest and constructive. Return JSON.

      #{UserText::PROMPT_RULE}

      #{RATING_RUBRIC}

      #{PLAIN_LANGUAGE_STANDARD}

      #{sections.join("\n\n")}
    CONTEXT
  end

  def build_review_section_prompt(exercise, daily_response, section)
    <<~PROMPT
      Grade ONLY the "#{section}" section from the day's context above.
      Pitched at: #{pitch_line(exercise, daily_response, section)}

      #{section_grading_note(exercise, daily_response, section)}

      Return a single JSON object (NOT wrapped in a "#{section}" key) with:
      - "rating": "beginner" | "developing" | "solid" | "strong"
      - "correct": array of strings — each entry one distinct thing they got right
      - "missed": array of strings — each entry one distinct thing they missed or got wrong
      - "essential_gaps": array of integers — the zero-based positions in "missed" of the entries that are essential gaps; an empty array when none are
      - "better_questions": array of strings — each entry one question they should have asked themselves
      - "next_step": string — one specific thing to study
      - "improved_code": string — #{improved_code_instruction(section)}

      Each array entry must be ONE self-contained idea in one or two sentences. Never pack
      several points into one entry, and never number points inside an entry ("1) ... 2) ...")
      — separate ideas belong in separate entries. Use an empty array when there is nothing to
      say for that field.
    PROMPT
  end

  # The rung only, never `eased`: the rubric grades an eased problem on what it actually asks.
  def pitch_line(exercise, daily_response, section)
    stamped = exercise.problem_set.dig(section, "pitched_at")
    rung = KindDifficulty::LEVELS.include?(stamped) ? stamped : current_rung(daily_response.user, section)
    "#{rung} — #{KindDifficulty::LEVEL_DEFINITIONS.fetch(rung)}"
  end

  def current_rung(user, section)
    difficulty = user ? KindDifficulty.for(user) : KindDifficulty.none
    difficulty.rung_for(ExerciseSection.for(section), skill_level: user&.skill_level)
  end

  def improved_code_instruction(section)
    kind = ExerciseSection.for(section)
    kind.improved_code? ?
      "the #{kind.improved_code_label.downcase} for this section" :
      "must be an empty string for this section"
  end

  def section_grading_note(exercise, daily_response, section)
    ExerciseSection.for(section).grading_note(
      section: exercise.problem_set[section] || {}, answer: daily_response.answer_for(section)
    )
  end

  # Time.zone is per thread, so carry the caller's zone or a fan-out's ApiUsage rows can land on another date.
  def thread_in_caller_zone(&work)
    zone = Time.zone
    Thread.new { Time.use_zone(zone, &work) }
  end

  # An abandoned thread may still write its ApiUsage row later, which is honest accounting for a call already billed.
  def awaited_difficulty(thread)
    thread.join(DIFFICULTY_ASSESSMENT_GRACE_SECONDS) ? thread.value : {}
  end

  # StandardError-wide around the whole thread: Thread#value would re-raise past #review's rescues and 500 a graded review.
  def safe_difficulty_assessment(user, exercise, sections)
    fresh_service.send(:assess_difficulty, user, exercise, sections: sections)
  rescue StandardError => e
    Rails.logger.warn("[difficulty] assessment failed: #{e.message}")
    {}
  end

  # Runs before the fan-out because #build_review_day_context reads the stored translation once for every grading thread.
  def translate_before_grading(user, exercise, daily_response, sections)
    sections.each do |section|
      next unless ExerciseSection.for(section).translated_before_grading?
      next if daily_response.translated?(section) || !daily_response.answered?(section)

      pseudocode = daily_response.answers[section].to_s
      next unless translatable_length?(pseudocode)

      code = translate_pseudocode(user, exercise, section: section, pseudocode: pseudocode)
      daily_response.record_translation!(section, code: code, pseudocode: pseudocode)
    rescue StandardError => e
      Rails.logger.warn("[pseudocode] review-time translation failed: #{e.message}")
    end
  end

  # Skipped rather than truncated: code from a clipped plan would be captioned as the engineer's plan.
  def translatable_length?(pseudocode)
    return true if pseudocode.length <= ExerciseSection::PseudocodeToCode::MAX_PSEUDOCODE_LENGTH

    Rails.logger.warn(
      "[pseudocode] review-time translation skipped: plan is #{pseudocode.length} characters, " \
      "over the #{ExerciseSection::PseudocodeToCode::MAX_PSEUDOCODE_LENGTH} limit"
    )
    false
  end

  # Tagged like provider errors so other sections still save; not StandardError, which would hide real bugs behind a retry.
  INFRASTRUCTURE_ERRORS = [
    ActiveRecord::ConnectionNotEstablished,
    Timeout::Error,
    IOError
  ].freeze

  # Only onto sections that graded; a section the day never asked about must not acquire one.
  def merge_difficulty!(results, difficulty)
    results.each do |section, result|
      next unless result[:ok] && difficulty[section]

      result[:review]["difficulty"] = difficulty[section]
    end
  end

  def grade_section(user, exercise, daily_response, section, context)
    service = fresh_service
    result  = service.send(
      :call_and_log, user, purpose: "review_response",
      system: context, prompt: service.send(:build_review_section_prompt, exercise, daily_response, section),
      cache_system: true, read_timeout: REVIEW_READ_TIMEOUT
    )
    # graded_prose and the rubric stamp are server-owned: only the prose judge writes one, and only this line the other.
    review = service.send(:parse_json_object, result[:text], subject: "#{section} review", log_raw: false)
                    .except(ReviewProseVerdict::ORIGINAL_KEY, "rubric").merge("rubric" => RUBRIC_VERSION)
    review = service.send(:rated, user, exercise, daily_response, section, review)
    review = service.send(:gaps_beside_their_prose, service.send(:judged_review, user, exercise, section, review))
    [ section, { ok: true, review: review } ]
  rescue AiService::Error, *INFRASTRUCTURE_ERRORS => e
    [ section, { ok: false, error_code: error_code_for(e), failure: ProviderFailure.classify(e),
                 provider: e.try(:provider) || service.class.provider_key,
                 quota_id: e.try(:quota_id), retry_after: e.try(:retry_after), failed_at: Time.current } ]
  end

  # A computed rating replaces the grader's, whose essential_gaps then describe a rating nobody kept, so it is not checked.
  def rated(user, exercise, daily_response, section, review)
    fixed = ExerciseSection.for(section).fixed_rating(
      section: exercise.problem_set[section] || {}, answer: daily_response.answer_for(section)
    )
    return review.merge("rating" => fixed).except("essential_gaps") if fixed

    checked_against_rubric(user, section, review)
  end

  # Runs before the prose judge, whose merges would renumber "missed".
  def checked_against_rubric(user, section, review)
    check  = RubricCheck.new(review)
    rating = ConceptMastery::AI_RATING_RANK.key?(review["rating"]) ? review["rating"] : "invalid"
    Rails.logger.info("[rubric_check] user=#{user.id} section=#{section} rating=#{rating} " \
                      "essential=#{check.essential_gaps&.size || 'unknown'} missed=#{check.missed_count} " \
                      "agrees=#{check.agrees?.nil? ? 'unknown' : check.agrees?}")
    check.essential_gaps ? review.merge("essential_gaps" => check.essential_gaps) : review.except("essential_gaps")
  end

  # The positions index the grader's "missed", so they move into graded_prose when the judge rewrote that list.
  def gaps_beside_their_prose(review)
    original = review[ReviewProseVerdict::ORIGINAL_KEY]
    return review unless original.is_a?(Hash) && review.key?("essential_gaps") && original["missed"] != review["missed"]

    review.except("essential_gaps").merge(ReviewProseVerdict::ORIGINAL_KEY => original.merge("essential_gaps" => review["essential_gaps"]))
  end

  # StandardError, because Thread#value re-raises anything grade_section's narrower rescue misses, costing the whole review.
  def judged_review(user, exercise, section, review)
    return review unless ReviewProseJudge.enabled? && self.class.judges_review_prose?

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    verdict = judge_review_prose(user, ExerciseSection.for(section), review, coach: config_for(exercise.language)[:coach])
    log_review_judge(user, section, verdict, started)
    verdict.apply(review)
  rescue StandardError => e
    Rails.logger.warn("[review_judge_fallback] user=#{user.id} section=#{section} reason=#{self.class.judge_fallback_reason(e)}")
    review
  end

  def log_review_judge(user, section, verdict, started)
    ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000).round
    Rails.logger.info("[review_judge] user=#{user.id} section=#{section} status=#{verdict.status} " \
                      "issues=#{verdict.issues.map { |issue| issue[:type] }.uniq.join(',')} " \
                      "merges=#{verdict.merges.to_json} ms=#{ms}")
  end

  # Handed no daily_response or history so it can't become a readout of the mastery tier; resist widening this signature.
  def assess_difficulty(user, exercise, sections:)
    result = call_and_log(
      user, purpose: "assess_difficulty", max_tokens: DIFFICULTY_ASSESSMENT_MAX_TOKENS,
      system: build_difficulty_system_prompt(config_for(exercise.language)[:coach]),
      prompt: build_difficulty_prompt(exercise, sections)
    )

    assessed = parse_json_object(result[:text], subject: "difficulty assessment")
    # Repairs rather than raises, so a bad assessment costs only the note; DailyResponse applies the rule again on read.
    sections.to_h { |section| [ section, DailyResponse.usable_difficulty(assessed[section]) ] }.compact
  end

  def build_difficulty_system_prompt(coach)
    "You are a senior #{coach} engineer rating how hard each of several practice problems is. " \
    "You are not grading anyone, and you will not be shown anyone's answer. Return JSON."
  end

  def build_difficulty_prompt(exercise, sections)
    material = sections.map { |section| "## #{section}\n#{duck_section_context(exercise, section)}" }

    <<~PROMPT
      Rate the objective difficulty of each problem below, on this scale:
      #{difficulty_scale}

      Judge only the material shown. Weigh how subtle the issue is, how many
      reasoning steps a complete answer takes, and how much the scenario leaves
      unstated. You know nothing about who is answering it, how they have done
      before, or why this problem was chosen for them — none of that is here,
      and none of it belongs in the rating. Two problems about the same idea can
      differ; "#{DailyResponse::DIFFICULTY_LEVELS.first}" is a perfectly good answer.

      Return a single JSON object keyed by the section names below:
      {
        "<section name>": {
          "level": #{DailyResponse::DIFFICULTY_LEVELS.map(&:inspect).join(' | ')},
          "reason": "string — one sentence of at most #{DailyResponse::MAX_DIFFICULTY_REASON_LENGTH} characters naming what makes it that, written for the engineer to read after their review"
        }
      }

      #{material.join("\n\n")}
    PROMPT
  end

  # Keyed by level from DailyResponse so labels can't shift; a spec, not the KeyError, catches a missing level.
  DIFFICULTY_GUIDANCE = {
    "straightforward" => "one thing to notice; a competent engineer finds it on a first read.",
    "moderate"        => "a couple of reasoning steps, or one detail that is easy to skim past.",
    "demanding"       => "the issue is subtle, several steps chain together, or the scenario leaves something material unstated."
  }.freeze

  def difficulty_scale
    DailyResponse::DIFFICULTY_LEVELS
      .map { |level| "- \"#{level}\" — #{DIFFICULTY_GUIDANCE.fetch(level)}" }
      .join("\n")
  end

  def build_concept_reference_prompt(concept, config)
    medium = LANGUAGE_AGNOSTIC_VOCABULARIES.include?(config[:concepts]) ? nil : config[:label]

    # Shapes to find are never techniques to choose, so they skip the remedy lens; design principles keep it.
    senior_lens_desc =
      if ANTI_SHAPE_CONCEPTS.include?(concept)
        "how to catch it early, what it costs to leave in place, and when the cheaper-looking shape is still worth refusing"
      else
        "when to reach for it / tradeoffs"
      end

    <<~PROMPT
      Write a durable reference for the #{config[:coach]} concept: "#{concept}".
      #{CONCEPT_REFERENCE_SCOPE} Be precise and senior-level.

      Then write a longer, plainer-language guide for someone meeting this
      concept in a library rather than in a problem — no exercise in front of
      them, no answer to reach. Thorough but not an essay: each guide field is
      at most two short paragraphs, except guide_worked_example, which carries
      its own bound below.

      This standard applies to the guide fields and the lesson:
      #{PLAIN_LANGUAGE_STANDARD}

      Then write a difficulty ladder: for each of #{KindDifficulty::LEVELS.join(', ')}, what a
      problem about THIS concept looks like at that level. Name its concrete form, never a
      description of the level in general. For missing_index, for example: junior is an
      unindexed foreign key, senior is composite index column order, principal_engineer is
      the write-cost tradeoff of adding an index. Each rung is one or two sentences, under
      #{MAX_LADDER_RUNG_LENGTH} characters.

      #{concept_lesson_instruction(concept)}

      Return JSON matching this schema exactly:
      {
        "tagline":      "string — bold one-liner",
        "explanation":  "string — 2-3 sentences",
        "code_example": "string — #{code_example_description(medium)}",
        "senior_lens":  "string — #{senior_lens_desc}",
        "guide_plain_language": "string — what this actually is, for a competent engineer who has never met the term",
        "guide_worked_example": "#{worked_example_description(concept, medium)}",
        "guide_pitfalls":       "string — what people get wrong about this, and why the wrong idea is appealing",
        "ladder_junior":             "string — a junior-level problem about this concept",
        "ladder_senior":             "string — a senior-level problem about this concept",
        "ladder_principal_engineer": "string — a principal_engineer-level problem about this concept",
        "lesson": #{JSON.generate(ConceptLesson.schema)}
      }
    PROMPT
  end

  # A tradeoff concept's habits are its options, and each catch is what that option costs.
  def concept_lesson_instruction(concept)
    habits =
      if TRADEOFF_CONCEPTS.include?(concept)
        "habits: one to #{ConceptLesson::MAX_HABITS} options a team can choose between. Each carries \"catch\": what that option costs."
      else
        "habits: one to #{ConceptLesson::MAX_HABITS} small habits or fixes. Each carries \"catch\": the real limit or cost of that habit, which the reader sees directly after it."
      end

    <<~TEXT.chomp
      Then write a short lesson for someone reading this concept on a phone, under
      "lesson". Every key in it is optional: leave a key out when it does not fit
      this concept, and never pad one to fill it.
      Keep the whole lesson under about #{ConceptLesson::WORD_TARGET} words, in plain prose with no code;
      the code example and the worked example already show the code.
      - definition: one sentence saying what the concept is.
      - comparison: an everyday comparison that maps onto the concept exactly.
      - comparison_limit: one sentence saying where that comparison stops working. Give it with comparison or leave both out; one without the other is dropped.
      - misunderstanding: the most common wrong idea about this concept, and what is true instead.
      - situations: two to #{ConceptLesson::MAX_SITUATIONS} concrete situations where an engineer runs into it, each one short.
      - #{habits}
      - carry_question: one question the reader can ask about their own work.
      - quick_test: a quick way to check their own code or plan for it.
    TEXT
  end

  def build_recognition_guide_prompt(group_key)
    concepts = RecognitionGuide.concepts_for(group_key)

    <<~PROMPT
      Write a short teaching piece on how to recognize one category of problem.

      The category, "#{group_key.humanize}", is about #{RecognitionGuide.subject_for(group_key)}
      The concepts in it are: #{concepts.join(', ')}.
      #{RecognitionGuide.framing_for(group_key)}
      #{recognition_tradeoff_line(concepts)}

      #{RECOGNITION_GUIDE_SCOPE}

      Write for any engineer reading a library, with no exercise in front of them.
      Keep examples language-neutral: plain description, or a few lines of
      pseudocode at most. Invent them; never describe a real exercise.

      This standard applies to every field:
      #{PLAIN_LANGUAGE_STANDARD}

      Return JSON matching this schema exactly:
      {
        "questions": "string — the questions to ask, in the order you would ask them, when reading code or a plan to see whether it has a problem of this kind. At most two short paragraphs.",
        "contrast":  "string — two short invented situations of the same shape: one where those questions turn something up, and a look-alike where they come back clean. Then say which question told them apart. At most two short paragraphs.",
        "misfires":  "string — how this way of looking goes wrong: what it flags that is not a problem, and what it misses. One short paragraph."
      }
    PROMPT
  end

  # Derived from TRADEOFF_CONCEPTS, so the framing follows the concepts wherever they are grouped.
  def recognition_tradeoff_line(concepts)
    choices = concepts & TRADEOFF_CONCEPTS
    return if choices.empty?

    "Some of these (#{choices.join(', ')}) are choices between two defensible options rather than defects. " \
      "For those, the lens recognizes that a choice is being made and which property of the context decides it, never which side is right."
  end

  # `medium` is nil for a concept with no code of its own (see LANGUAGE_AGNOSTIC_VOCABULARIES).
  def code_example_description(medium)
    return "illustrative pseudocode or a short language-agnostic snippet, ~15 lines" if medium.nil?

    "annotated #{medium} code, ~15 lines"
  end

  # The tradeoff branch withholds "corrected": both options are legitimate, and a flaw/fix frame implies one right answer.
  def worked_example_description(concept, medium)
    opening = "two short #{medium || 'pseudocode'} fragments of the SAME scenario, " \
              "keeping the same names and shape so the difference reads structurally"

    if TRADEOFF_CONCEPTS.include?(concept)
      "string — #{opening}: option A, then option B. NEITHER is the corrected version — both are " \
        "legitimate and the choice is context-dependent. Then say in prose what each option buys, what it " \
        "costs, and which property of the context decides between them. #{WORKED_EXAMPLE_BOUND}"
    else
      "string — #{opening}: first the version exhibiting the concept's failure mode, then the " \
        "corrected version of that same scenario. Then say in prose WHY the two relate as a mechanism " \
        "('X causes Y', 'Y is what happens when X breaks down') — never merely that they are " \
        "associated or related. #{WORKED_EXAMPLE_BOUND}"
    end
  end

  # A non-Hash must fail here: an array saved to ai_review is truthy, flips #reviewed? and strands an empty review.
  def parse_json_object(text, subject:, log_raw: true)
    parsed = parse_json_response(text, subject: subject, log_raw: log_raw)
    return parsed if parsed.is_a?(Hash)

    raise InvalidResponseError, "Provider returned #{parsed.class} instead of a JSON object for the #{subject}"
  end

  # log_raw: false keeps replies that may quote an answer or hold an answer key out of logs; the message never quotes them.
  def parse_json_response(text, subject: "response", log_raw: true)
    # Strip any accidental markdown fences
    clean = text.to_s.gsub(/\A```(?:json)?\n?/, "").gsub(/\n?```\z/, "").strip
    JSON.parse(clean)
  rescue JSON::ParserError => e
    raise InvalidResponseError, "Provider returned invalid JSON for the #{subject}" unless log_raw

    log_raw_snippet("Invalid JSON from provider", text)
    raise InvalidResponseError, "Provider returned invalid JSON: #{e.message}"
  end

  # Callers rescue AiService::Error, so a non-object body (an HTML page, a cut-off reply) must arrive as one.
  def parse_provider_envelope(body, provider:)
    parsed = JSON.parse(body.to_s)
    return parsed if parsed.is_a?(Hash)

    unreadable_envelope!(body, provider)
  rescue JSON::ParserError
    unreadable_envelope!(body, provider)
  end

  # A body that starts like JSON may carry an answer the logs must not, so only its size is logged.
  def unreadable_envelope!(body, provider)
    text = body.to_s
    if text.lstrip.start_with?("{", "[", '"')
      Rails.logger.error("Unreadable #{provider} response body: #{text.bytesize} bytes of cut-off JSON, withheld")
    else
      log_raw_snippet("Unreadable #{provider} response body", text)
    end
    raise InvalidResponseError, "#{provider} returned an unreadable response"
  end

  # Every provider nests error detail as {"error": {"message": ...}}; anything else falls back to `fallback`.
  def extract_provider_message(body, fallback:)
    parsed  = JSON.parse(body.to_s)
    message = parsed.is_a?(Hash) ? parsed.dig("error", "message") : nil
    message.presence || fallback
  rescue JSON::ParserError
    fallback
  end

  # The body can echo the key, so it is neither logged nor shown; the status says enough.
  def raise_if_key_rejected(company, status)
    return unless [ 401, 403 ].include?(status)

    Rails.logger.error("#{company} authentication failed (HTTP #{status})")
    raise AuthenticationError.new("#{company} rejected your API key or its permissions. Check it in Settings.",
                                  http_status: status)
  end

  # Logged instead of put in an exception message, which reaches flash alerts and error trackers.
  def log_raw_snippet(label, content)
    text = content.to_s
    # .scrub repairs a multi-byte character byteslice may cut in half.
    snippet = text.byteslice(0, RAW_SNIPPET_LIMIT).scrub
    snippet += "... (truncated, #{text.bytesize} bytes total)" if text.bytesize > RAW_SNIPPET_LIMIT
    Rails.logger.error("#{label}: #{snippet}")
  end

  # Rescued per suggestion, so one bad name can't discard the rest; a failure here never breaks generation.
  def record_suggested_concepts(suggestions)
    suggestions.each { |suggestion| record_suggested_concept(suggestion) }
  end

  def record_suggested_concept(suggestion)
    SuggestedConcept.record!(language: suggestion.bucket, name: suggestion.name)
  rescue => e
    Rails.logger.warn("SuggestedConcept recording failed: #{e.message}")
  end

  # Carries the same key and credential kind into another thread of the same call.
  def fresh_service
    self.class.new(@api_key).tap { |service| service.house_key = house_key? }
  end

  # Rescues database errors only; swallowing anything else would silently empty the table cost questions rely on.
  def log_usage(user, result, purpose:)
    ActiveRecord::Base.connection_pool.with_connection do
      ApiUsage.create!(
        user:       user,
        house_key:  house_key?,
        tokens_in:  result[:input_tokens].to_i,
        tokens_out: result[:output_tokens].to_i,
        model:      result[:model],
        provider:   self.class.provider_key,
        cache_read_tokens:  result[:cache_read_tokens],
        cache_write_tokens: result[:cache_write_tokens],
        http_status: result[:http_status],
        failure:     result[:failure],
        quota_id:    result[:quota_id],
        purpose:    purpose,
        date:       Date.current
      )
    end
  rescue ActiveRecord::ActiveRecordError => e
    Rails.logger.warn(
      "[usage] ApiUsage log failed for purpose=#{purpose} user_id=#{user&.id} " \
      "tokens_in=#{result[:input_tokens].to_i} tokens_out=#{result[:output_tokens].to_i}: " \
      "#{e.class}: #{e.message}"
    )
  end

  # The one path every provider call takes, so usage rows are written before any failure, truncation or refusal raises.
  def call_and_log(user, purpose:, system:, prompt:, cache_system: false,
                   read_timeout: READ_TIMEOUT, max_tokens: nil, history: [], response_schema: nil, allow_truncated: false, single_attempt: false)
    TrialAllowance.check!(user, provider: self.class) if house_key?
    begin
      result = call(system: system, prompt: prompt, cache_system: cache_system,
                    read_timeout: read_timeout, max_tokens: max_tokens, history: history, purpose: purpose,
                    response_schema: response_schema, single_attempt: single_attempt)
    rescue Error => e
      e.provider ||= self.class.provider_key
      log_usage(user, failed_call_result(e, purpose), purpose: purpose)
      raise
    end
    log_usage(user, result.merge(failure: reply_failure_code(result, allow_truncated)), purpose: purpose)

    raise Error, result[:error] if result[:error]
    raise RefusalError, "The provider declined this request (#{result[:refusal]})" if result[:refusal]

    if result[:truncated] && !allow_truncated
      raise TruncatedResponseError,
            "Provider did not finish its reply " \
            "(#{result[:output_tokens].to_i} output tokens, thinking included)"
    end

    result
  end

  def failed_call_result(error, purpose)
    { input_tokens: 0, output_tokens: 0, model: routed_model(purpose),
      http_status: error.http_status, failure: self.class.failure_code_for(error), quota_id: error.quota_id }
  end

  # An unusable reply is still billed, so its row keeps the tokens and names why it was not used.
  def reply_failure_code(result, allow_truncated)
    return "provider_error" if result[:error]
    return "refusal" if result[:refusal]
    return "truncated" if result[:truncated] && !allow_truncated

    nil
  end

  # Providers override; the base knows no routes.
  def routed_model(_purpose) = nil

  # Read for a quota id or error code, never logged: an error body can carry the key.
  def parse_error_body(body)
    parsed = JSON.parse(body.to_s)
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError
    {}
  end

  # Empty when the body is not JSON or has no "error", so the status alone decides.
  def error_envelope(body)
    error = parse_error_body(body)["error"]
    error.is_a?(Hash) ? error : {}
  end

  # A provider whose quota day has a known boundary overrides this; the base gives a day.
  def self.daily_quota_reset_at(failed_at)
    failed_at + 1.day
  end

  # The provider's requested wait in whole seconds, from the standard header.
  def retry_after_seconds(resp)
    value = resp.headers["retry-after"].to_s
    value.match?(/\A\d+\z/) ? value.to_i : nil
  end
end
