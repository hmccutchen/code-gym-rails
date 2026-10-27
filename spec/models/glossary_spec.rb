require "rails_helper"

module GlossaryLengthRule
  LONG_ENTRIES = [
    "aggregate boundaries", "allocation rounding", "debouncing throttling", "reading for intent",
    "reconciliation", "semantic input validation", "shallow module", "spotting unstated assumptions",
    "strict mode", "throttling", "ubiquitous language", "wrong cardinality"
  ].freeze
  MAX_CHARS = 180
  CEILING_CHARS = 300
end

RSpec.describe Glossary do
  it "stores every key already lowercased, since key_for downcases only the text it looks up" do
    Glossary::TERMS.keys.each do |key|
      expect(key).to eq(key.downcase)
    end
  end

  it "has no blank definitions" do
    expect(Glossary::TERMS.values).to all(be_present)
  end

  # The coverage guard tries only underscore_case, so hyphenated spellings in prose need their own key.
  it "carries the hyphenated spelling of every term written that way in prose" do
    expect(Glossary::TERMS["pass-through method"]).to be_present
  end

  # Users search for the words the app shows them; "concurrency" once had no glossary hit at all.
  it "resolves every ConceptVocabulary entry, in its literal or space-normalized form" do
    concepts = ConceptVocabulary::RAILS_CONCEPTS + ConceptVocabulary::JS_CONCEPTS + ConceptVocabulary::ARCHITECTURE_CONCEPTS
    missing = concepts.uniq.reject do |concept|
      Glossary.key_for(concept) || Glossary.key_for(concept.tr("_", " "))
    end

    expect(missing).to be_empty
  end

  describe ".pattern_for" do
    it "matches the longer of two overlapping terms" do
      pattern = Glossary.pattern_for("partial index" => "x", "index" => "y")

      expect("a partial index helps"[pattern]).to eq("partial index")
    end

    it "matches a form, preferring the longer form to a shorter one inside it" do
      pattern = Glossary.pattern_for({ "indexing" => "x", "composite index" => "y" }, { "indexing" => %w[indexes], "composite index" => [ "composite indexes" ] })

      expect("add composite indexes"[pattern]).to eq("composite indexes")
    end

    it "matches no form when none are passed" do
      expect("it is memoized"[Glossary.pattern_for("memoization" => "x")]).to be_nil
    end
  end

  describe ".key_for" do
    it "resolves a form to its key" do
      expect(Glossary.key_for("memoized")).to eq("memoization")
      expect(Glossary.key_for("Service Objects")).to eq("service object")
      expect(Glossary.key_for("denormalizing")).to eq("denormalization")
      expect(Glossary.key_for("god objects")).to eq("god object")
    end

    it "resolves a key to itself and an unknown word to nil" do
      expect(Glossary.key_for("Closure")).to eq("closure")
      expect(Glossary.key_for("nonexistentword")).to be_nil
    end

    it "gives the plural duplicates no key of their own" do
      expect(Glossary::TERMS.keys & [ "background jobs", "closures", "policy objects", "query objects", "service objects" ]).to be_empty
      expect(Glossary.key_for("closures")).to eq("closure")
    end
  end

  describe "LOOKUP" do
    it "resolves a key and a form, and is frozen so no request can change it" do
      expect(Glossary::LOOKUP["closure"]).to eq("closure")
      expect(Glossary::LOOKUP["closures"]).to eq("closure")
      expect(Glossary::LOOKUP).to be_frozen
    end

    it "is rebuilt for any terms and forms by lookup_for" do
      lookup = Glossary.lookup_for({ "foo" => "x" }, { "foo" => %w[foos] })

      expect(lookup).to eq("foo" => "foo", "foos" => "foo")
    end
  end

  # Reviews of Rails code use both words in their Rails sense, so neither definition may describe only one stack.
  describe "terms reviews use across stacks" do
    it "defines callback to cover a Rails model hook as well as a function passed in" do
      expect(Glossary::TERMS["callback"]).to include("after_save").and include("function")
    end

    it "defines ref beyond React's useRef" do
      expect(Glossary::TERMS["ref"]).to include("useRef")
      expect(Glossary::TERMS["ref"]).not_to start_with("In React")
    end
  end

  describe ".forms_for" do
    it "returns a key with its forms, from the key or from any of its forms" do
      expect(Glossary.forms_for("memoization")).to eq(%w[memoization memoized memoizing memoize memoised])
      expect(Glossary.forms_for("Memoized")).to eq(%w[memoization memoized memoizing memoize memoised])
    end

    it "returns a key with no forms alone, and nothing for an unknown word" do
      expect(Glossary.forms_for("caching")).to eq(%w[caching])
      expect(Glossary.forms_for("nonexistentword")).to eq([])
    end
  end

  describe ".definition_for" do
    it "returns the definition for a key or a form, and nil for an unknown word" do
      expect(Glossary.definition_for("Closures")).to eq(Glossary::TERMS["closure"])
      expect(Glossary.definition_for("closure")).to eq(Glossary::TERMS["closure"])
      expect(Glossary.definition_for("nonexistentword")).to be_nil
    end
  end

  describe "the reference-audit entries" do
    let(:audit_keys) do
      [
        "unique index", "invariant", "reducer", "seam", "happy path", "dependency array", "ref", "adapter",
        "blast radius", "eventual consistency", "replica", "tenant", "connection pool", "context provider",
        "partial index", "query planner", "react.memo", "soft delete", "ttl", "abortcontroller",
        "atomic operation", "code smell", "contention", "dead-letter queue", "external store", "fixture",
        "guard clause", "hot key", "low selectivity", "p99 latency", "polyfill", "row lock",
        "idempotency key", "backfill", "compensating action", "form object", "value object"
      ]
    end

    it "defines every term the audit found in three or more references" do
      expect(audit_keys.size).to eq(37)
      expect(audit_keys - Glossary::TERMS.keys).to be_empty
    end

    it "leaves the words the wrong-sense listing caught in another sense unmatched" do
      [ "indexes", "indexed", "injected", "inferred", "injecting", "normalize", "normalized", "lift it up" ].each do |word|
        expect(Glossary.key_for(word)).to be_nil, "#{word} matched again; the production listing read it in another sense"
      end
    end

    it "resolves a plural to its singular entry rather than to a shorter key inside it" do
      expect(Glossary.key_for("unique indexes")).to eq("unique index")
      expect(Glossary.key_for("Dead-letter queues")).to eq("dead-letter queue")
      expect("two unique indexes"[Glossary::TERM_PATTERN]).to eq("unique indexes")
    end

    it "matches React.memo as one token, dot included" do
      expect("wrap it in React.memo first"[Glossary::TERM_PATTERN]).to eq("React.memo")
      expect(Glossary.key_for("React.memo")).to eq("react.memo")
    end
  end

  describe "FORMS" do
    it "lets no form equal a key or another key's form" do
      forms = Glossary::FORMS.values.flatten

      expect(forms & Glossary::TERMS.keys).to be_empty
      expect(forms.size).to eq(forms.uniq.size)
    end

    it "is lowercase and belongs to keys that exist" do
      expect(Glossary::FORMS.keys - Glossary::TERMS.keys).to be_empty
      expect(Glossary::FORMS.values.flatten.map { |form| form == form.downcase }).to all(be(true))
    end
  end

  describe "definition length" do
    def over_the_rule(definition)
      SentenceCount.of(definition) > 1 || definition.length > GlossaryLengthRule::MAX_CHARS
    end

    it "keeps every definition at or under the ceiling, listed or not" do
      too_long = Glossary::TERMS.select { |_key, definition| definition.length > GlossaryLengthRule::CEILING_CHARS }

      report = too_long.map { |key, definition| "#{key} (#{definition.length} chars)" }

      expect(report).to be_empty, "over #{GlossaryLengthRule::CEILING_CHARS} chars: #{report.join('; ')}"
    end

    it "holds every unlisted definition to one sentence of at most 180 characters" do
      offenders = Glossary::TERMS.reject { |key, _| GlossaryLengthRule::LONG_ENTRIES.include?(key) }.select { |_key, definition| over_the_rule(definition) }

      report = offenders.map { |key, definition| "#{key} (#{SentenceCount.of(definition)} sentence(s), #{definition.length} chars)" }

      expect(report).to be_empty, "shorten to one sentence of at most #{GlossaryLengthRule::MAX_CHARS} chars: #{report.join('; ')}"
    end

    # Without this a fixed entry would stay listed and the list would slowly stop meaning anything.
    it "lists only keys that still need listing, and only keys that exist" do
      expect(GlossaryLengthRule::LONG_ENTRIES - Glossary::TERMS.keys).to be_empty
      stale = GlossaryLengthRule::LONG_ENTRIES.select { |key| Glossary::TERMS[key] && !over_the_rule(Glossary::TERMS[key]) }

      expect(stale).to be_empty, "now one short sentence, remove from GlossaryLengthRule::LONG_ENTRIES: #{stale.join(', ')}"
    end
  end

  describe "entries that reference pages read in two senses" do
    it "defines strict mode for JavaScript and for React" do
      expect(Glossary::TERMS["strict mode"]).to match(/use strict/).and match(/React/)
    end

    it "defines reconciliation as repairing differences and as React's render diff" do
      expect(Glossary::TERMS["reconciliation"]).to match(/repair/i).and match(/React/)
    end

    it "defines throttling for a function and for a processor" do
      expect(Glossary::TERMS["throttling"]).to match(/interval/).and match(/CPU|processor/)
    end
  end
end
