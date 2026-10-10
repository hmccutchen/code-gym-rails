# Never sent to a provider; a pointer names a term the book coined, never a chapter or page. See CLAUDE.md.
module ConceptBookSources
  APOSD      = { title: "A Philosophy of Software Design", author: "John Ousterhout" }.freeze
  CLEAN_CODE = { title: "Clean Code",                      author: "Robert C. Martin" }.freeze
  DDD        = { title: "Domain-Driven Design",            author: "Eric Evans" }.freeze
  POODR      = { title: "Practical Object-Oriented Design in Ruby", author: "Sandi Metz" }.freeze
  PRAGMATIC  = { title: "The Pragmatic Programmer",        author: "Andrew Hunt and David Thomas" }.freeze
  REFACTORING = { title: "Refactoring",                    author: "Martin Fowler" }.freeze

  def self.source(book, pointer = nil)
    pointer ? book.merge(pointer: pointer).freeze : book
  end
  private_class_method :source

  SOURCES = {
    "aggregate_boundaries" => [
      source(DDD, "Aggregates and the aggregate root")
    ],
    "api_versioning" => [
      source(PRAGMATIC)
    ],
    "array_mutation_pitfalls" => [
      source(REFACTORING, "the Mutable Data smell")
    ],
    "build_vs_buy" => [
      source(PRAGMATIC),
      source(CLEAN_CODE)
    ],
    "composition_over_inheritance" => [
      source(POODR),
      source(REFACTORING, "the Refused Bequest smell")
    ],
    "concurrency" => [
      source(PRAGMATIC)
    ],
    "conflated_responsibilities" => [
      source(CLEAN_CODE)
    ],
    "coupling_cohesion" => [
      source(PRAGMATIC, "orthogonality"),
      source(CLEAN_CODE)
    ],
    "dependency_inversion" => [
      source(POODR),
      source(CLEAN_CODE),
      source(DDD, "the Anticorruption Layer")
    ],
    "error_handling" => [
      source(PRAGMATIC, "crash early"),
      source(CLEAN_CODE)
    ],
    "event_driven_vs_request_response" => [
      source(DDD, "Domain Events")
    ],
    "feature_envy" => [
      source(REFACTORING, "the Feature Envy, Message Chains and Insider Trading smells"),
      source(DDD),
      source(PRAGMATIC)
    ],
    "god_object" => [
      source(REFACTORING, "the Large Class and Divergent Change smells"),
      source(CLEAN_CODE)
    ],
    "missing_constraint" => [
      source(PRAGMATIC)
    ],
    "open_closed" => [
      source(REFACTORING, "the Repeated Switches smell")
    ],
    "over_mocking" => [
      source(CLEAN_CODE)
    ],
    "pass_through_method" => [
      source(APOSD, "shallow modules"),
      source(REFACTORING, "the Middle Man and Lazy Element smells")
    ],
    "policy_objects" => [
      source(DDD, "the Specification pattern")
    ],
    "primitive_obsession" => [
      source(REFACTORING, "the Primitive Obsession and Data Clumps smells"),
      source(DDD, "value objects")
    ],
    "query_objects" => [
      source(DDD, "the Repository pattern")
    ],
    "reading_for_intent" => [
      source(CLEAN_CODE),
      source(REFACTORING, "the Mysterious Name smell")
    ],
    "scope_creep" => [
      source(REFACTORING, "the Speculative Generality smell")
    ],
    "semantic_input_validation" => [
      source(PRAGMATIC),
      source(DDD, "the Anticorruption Layer")
    ],
    "separating_symptom_from_cause" => [
      source(PRAGMATIC, "programming by coincidence")
    ],
    "service_boundaries" => [
      source(DDD, "Bounded Contexts")
    ],
    "shallow_module" => [
      source(APOSD, "deep and shallow modules"),
      source(CLEAN_CODE),
      source(REFACTORING, "the Lazy Element smell")
    ],
    "shotgun_surgery" => [
      source(REFACTORING, "the Shotgun Surgery and Duplicated Code smells"),
      source(PRAGMATIC, "DRY")
    ],
    "spotting_unstated_assumptions" => [
      source(PRAGMATIC, "programming by coincidence")
    ],
    "testing_implementation_not_behavior" => [
      source(CLEAN_CODE)
    ],
    "transaction_safety" => [
      source(PRAGMATIC)
    ],
    "ubiquitous_language" => [
      source(DDD, "the Ubiquitous Language")
    ],
    "undefined_failure_path" => [
      source(PRAGMATIC, "crash early"),
      source(CLEAN_CODE)
    ],
    "unjustified_constant" => [
      source(PRAGMATIC)
    ],
    "unstated_mutation" => [
      source(REFACTORING, "the Mutable Data and Temporary Field smells"),
      source(CLEAN_CODE)
    ],
    "validations" => [
      source(PRAGMATIC)
    ]
  }.freeze

  # [] rather than nil: every caller renders a list.
  def self.for(concept)
    SOURCES.fetch(concept.to_s, [])
  end

  # The pointers are the only hand-written words here; titles and authors are the books' own.
  def self.learn_text
    SOURCES.each_with_object({}) do |(concept, sources), texts|
      sources.each_with_index do |source, index|
        texts["sources:#{concept}:#{index}"] = source[:pointer] if source[:pointer]
      end
    end
  end
end
