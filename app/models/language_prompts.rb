module LanguagePrompts
  ALL = {
    "ruby_rails" => {
      label:             "Ruby/Rails",
      coach:             "Rails",
      test_framework:    "an RSpec-style",
      schema_artifact:   "a Rails migration",
      focus:             "real Rails patterns: N+1 queries, idempotency, background jobs, authorization, service objects, query objects, policy objects."
    },
    "javascript" => {
      label:             "JavaScript/React",
      coach:             "JavaScript/React",
      test_framework:    "a Jest/Vitest-style",
      schema_artifact:   "a Prisma schema change, with the migration it generates",
      focus:             "real JavaScript/React patterns: closures, async/event-loop pitfalls, prototypal inheritance, `this` binding, and hooks/re-renders."
    },
    "architecture" => {
      label:    "language-agnostic",
      coach:    "software architecture",
      focus:    "system-design tradeoffs: service boundaries, consistency, failure modes, scale, coupling."
    },
    "plan_review" => {
      label:    "language-agnostic",
      coach:    "engineering plan review",
      focus:    "spotting flaws in a written implementation plan before it's built: unjustified complexity, scope creep, and unflagged behavior changes."
    },
    "ambiguity_hunt" => {
      label:    "language-agnostic",
      coach:    "requirements analysis",
      focus:    "interrogating an underspecified feature request: missing scope boundaries, unhandled edge cases, and unstated success criteria."
    },
    "pseudocode_to_code" => {
      label:    "language-agnostic",
      coach:    "algorithm design",
      focus:    "turning an informal plan into something that actually works: base cases, empty input, boundaries, ordering, and the failure paths a plan leaves undefined."
    }
  }.freeze

  def self.for(language)
    ALL.fetch(language) do
      raise SetupError, "Unsupported generation language: #{language.inspect}"
    end
  end
end
