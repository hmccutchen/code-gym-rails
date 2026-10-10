# Design notes: docs/code-notes/app/models/concept_vocabulary.md
module ConceptVocabulary
  class UnknownLanguage < StandardError; end

  DATA_MODELING_CONCEPTS = %w[
    missing_index wrong_cardinality missing_constraint
    denormalization_tradeoffs unsafe_migration
  ].freeze

  META_SKILL_CONCEPTS = %w[
    reading_for_intent spotting_unstated_assumptions separating_symptom_from_cause
  ].freeze

  CODE_SMELL_CONCEPTS = %w[
    god_object primitive_obsession shotgun_surgery feature_envy
  ].freeze

  OO_DESIGN_CONCEPTS = %w[
    open_closed dependency_inversion composition_over_inheritance
  ].freeze

  MODULE_DESIGN_CONCEPTS = %w[
    shallow_module pass_through_method temporal_decomposition
  ].freeze

  SILENT_CORRECTNESS_CONCEPTS = %w[
    allocation_rounding semantic_input_validation cache_key_completeness
    deterministic_ordering
  ].freeze

  DOMAIN_MODELING_CONCEPTS = %w[
    ubiquitous_language aggregate_boundaries
  ].freeze

  COMPLEXITY_CAUSE_CONCEPTS = %w[
    cognitive_load unknown_unknowns
  ].freeze

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

  RAILS_SECURITY_CONCEPTS = %w[mass_assignment_protection sql_injection_prevention].freeze
  JS_SECURITY_CONCEPTS    = %w[xss_prevention insecure_client_storage].freeze

  TYPESCRIPT_FLAVORED_CONCEPTS = %w[
    generics type_guards_narrowing union_intersection_types mapped_conditional_types
  ].freeze

  ARCHITECTURE_CONCEPTS = (%w[
    sync_vs_async service_boundaries coupling_cohesion data_consistency_tradeoffs
    caching_strategy build_vs_buy scaling_bottlenecks failure_mode_design
    api_versioning event_driven_vs_request_response data_ownership
    idempotency_at_scale observability_tradeoffs
  ] + COMPLEXITY_CAUSE_CONCEPTS).freeze

  TRADEOFF_CONCEPTS = %w[
    sync_vs_async service_boundaries coupling_cohesion data_consistency_tradeoffs
    caching_strategy build_vs_buy scaling_bottlenecks failure_mode_design
    api_versioning event_driven_vs_request_response data_ownership
    idempotency_at_scale observability_tradeoffs
    denormalization_tradeoffs
  ].freeze

  PLAN_REVIEW_CONCEPTS = %w[
    unjustified_constant contradicts_existing_pattern scope_creep silent_behavior_change
  ].freeze

  AMBIGUITY_HUNT_CONCEPTS = %w[
    undefined_scope_boundary unspecified_edge_cases missing_success_criteria
    unstated_data_implications undefined_permissions_model
  ].freeze

  PSEUDOCODE_TO_CODE_CONCEPTS = %w[
    missing_base_case unhandled_empty_input off_by_one_boundary ambiguous_ordering
    unstated_mutation conflated_responsibilities missing_termination_condition
    undefined_failure_path
  ].freeze

  LANGUAGES = {
    "ruby_rails"         => { concepts: RAILS_CONCEPTS, security_concepts: RAILS_SECURITY_CONCEPTS },
    "javascript"         => { concepts: JS_CONCEPTS, security_concepts: JS_SECURITY_CONCEPTS },
    "architecture"       => { concepts: ARCHITECTURE_CONCEPTS },
    "plan_review"        => { concepts: PLAN_REVIEW_CONCEPTS },
    "ambiguity_hunt"     => { concepts: AMBIGUITY_HUNT_CONCEPTS },
    "pseudocode_to_code" => { concepts: PSEUDOCODE_TO_CODE_CONCEPTS }
  }.freeze

  LANGUAGE_AGNOSTIC_VOCABULARIES = [ ARCHITECTURE_CONCEPTS, PLAN_REVIEW_CONCEPTS,
                                     AMBIGUITY_HUNT_CONCEPTS, PSEUDOCODE_TO_CODE_CONCEPTS ].freeze

  # Order is the Learn index's display order, and a concept in two groups takes the first.
  GROUPS = {
    data_modeling:      DATA_MODELING_CONCEPTS,
    domain_modeling:    DOMAIN_MODELING_CONCEPTS,
    silent_correctness: SILENT_CORRECTNESS_CONCEPTS,
    meta_skill:         META_SKILL_CONCEPTS,
    code_smell:         CODE_SMELL_CONCEPTS,
    oo_design:          OO_DESIGN_CONCEPTS,
    module_design:      MODULE_DESIGN_CONCEPTS
  }.freeze

  def self.languages = LANGUAGES.keys

  def self.for_language(language) = language_entry(language).fetch(:concepts)

  def self.security_for_language(language) = language_entry(language).fetch(:security_concepts)

  def self.language_agnostic?(language) = LANGUAGE_AGNOSTIC_VOCABULARIES.include?(for_language(language))

  # Never narrowed: a concept the provider tagged is history, and rewriting it to "other" would destroy the record.
  def self.for_section(section_key, language)
    case (key = ExerciseSection.find(section_key)&.vocabulary_key)
    when nil, :concepts     then for_language(language)
    when :security_concepts then security_for_language(language)
    else                         for_language(key.to_s)
    end
  end

  def self.selectable_for_section(section_key, language, mode: nil, rung: nil)
    vocabulary =
      if mode && section_key == ExerciseSection::CodeReview.key
        code_review_vocabulary(language, mode)
      else
        for_section(section_key, language)
      end

    excluded = excluded_concepts_for(section_key)
    remaining = excluded.empty? ? vocabulary : vocabulary - excluded
    ExerciseSection.for(section_key).narrow_vocabulary(remaining, rung: rung) & remaining
  end

  def self.code_review_vocabulary(language, mode)
    full = for_language(language)
    mode == :schema_review ? DATA_MODELING_CONCEPTS : full - DATA_MODELING_CONCEPTS
  end
  private_class_method :code_review_vocabulary

  def self.excluded_concepts_for(section_key)
    ExerciseSection.for(section_key).excluded_vocabulary_keys.flat_map { |key| GROUPS.fetch(key) }
  end
  private_class_method :excluded_concepts_for

  def self.language_entry(language)
    LANGUAGES.fetch(language) do
      raise UnknownLanguage, "Unsupported generation language: #{language.inspect}"
    end
  end
  private_class_method :language_entry
end
