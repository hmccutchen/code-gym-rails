# Static, hand-curated reading pointers for concepts this app grades — the
# single source of truth for the "Where this comes from" block on a Learn page.
# Extend it by adding one line; nothing writes to this file automatically.
#
# Curated rather than generated, and NEVER sent to a provider. A generated
# citation is a hallucinated citation, and a ConceptReference row is cached
# forever, so a wrong one would never self-correct. That is also why the
# citation lives here instead of in a concept_references column: the guarantee
# is that no prompt can reach this data, not that a prompt is asked to behave.
#
# Three rules for an entry, none of which anything mechanical can enforce:
#
# - `pointer` names a term the book itself coined ("the Shotgun Surgery smell",
#   "DRY", "Bounded Context"). Never a chapter number and never a page — a
#   number recalled rather than checked is a fabrication that reads as
#   authoritative. Where a book has no coined term for the idea, the field is
#   omitted rather than invented.
# - Never a quotation or a close paraphrase. This is a pointer to go read the
#   book, not a substitute for reading it.
# - A concept's sources are listed origin-first, so the book that introduced
#   the term precedes a book that merely also covers it.
#
# Values are ARRAYS from the first day rather than a single source promoted
# later: shotgun_surgery carries two on day one.
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
      source(PRAGMATIC, "reversibility")
    ],
    "array_mutation_pitfalls" => [
      source(REFACTORING, "the Mutable Data smell")
    ],
    "build_vs_buy" => [
      source(PRAGMATIC, "reversibility"),
      source(CLEAN_CODE, "boundaries around third-party code")
    ],
    "composition_over_inheritance" => [
      source(POODR),
      source(REFACTORING, "the Refused Bequest smell")
    ],
    "concurrency" => [
      source(PRAGMATIC, "shared state")
    ],
    "conflated_responsibilities" => [
      source(CLEAN_CODE, "functions should do one thing")
    ],
    "coupling_cohesion" => [
      source(PRAGMATIC, "orthogonality"),
      source(CLEAN_CODE, "cohesion")
    ],
    "dependency_inversion" => [
      source(POODR, "managing dependencies"),
      source(CLEAN_CODE, "boundaries around third-party code"),
      source(DDD, "the Anticorruption Layer")
    ],
    "error_handling" => [
      source(PRAGMATIC, "crash early"),
      source(CLEAN_CODE, "don't return null")
    ],
    "event_driven_vs_request_response" => [
      source(DDD, "Domain Events")
    ],
    "feature_envy" => [
      source(REFACTORING, "the Feature Envy, Message Chains and Insider Trading smells"),
      source(DDD, "the Anemic Domain Model"),
      source(PRAGMATIC, "the Law of Demeter")
    ],
    "god_object" => [
      source(REFACTORING, "the Large Class and Divergent Change smells"),
      source(CLEAN_CODE, "classes should be small")
    ],
    "missing_constraint" => [
      source(PRAGMATIC, "design by contract")
    ],
    "open_closed" => [
      source(REFACTORING, "the Repeated Switches smell")
    ],
    "over_mocking" => [
      source(CLEAN_CODE, "clean tests")
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
      source(CLEAN_CODE, "meaningful names"),
      source(REFACTORING, "the Mysterious Name smell")
    ],
    "scope_creep" => [
      source(REFACTORING, "the Speculative Generality smell")
    ],
    "semantic_input_validation" => [
      source(PRAGMATIC, "design by contract"),
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
      source(CLEAN_CODE, "function arguments"),
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
      source(CLEAN_CODE, "clean tests")
    ],
    "transaction_safety" => [
      source(PRAGMATIC, "shared state")
    ],
    "ubiquitous_language" => [
      source(DDD, "the Ubiquitous Language")
    ],
    "undefined_failure_path" => [
      source(PRAGMATIC, "crash early"),
      source(CLEAN_CODE, "error handling")
    ],
    "unjustified_constant" => [
      source(PRAGMATIC, "parameterize from the outside")
    ],
    "unstated_mutation" => [
      source(REFACTORING, "the Mutable Data and Temporary Field smells"),
      source(CLEAN_CODE, "command-query separation")
    ],
    "validations" => [
      source(PRAGMATIC, "design by contract")
    ]
  }.freeze

  # [] rather than nil: every caller renders a list, and most concepts have no
  # citation yet.
  def self.for(concept)
    SOURCES.fetch(concept.to_s, [])
  end
end
