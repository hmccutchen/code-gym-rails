require "rails_helper"

# ProblemSetIngest's own tests. The front door is .call; the examples below
# reach individual steps through the `step` helper, which is legitimate here
# and only here.
#
# NO TEST OUTSIDE THIS FILE MAY TOUCH A STEP. Steps are internal seams — the
# module's tests may use them, callers and their tests may not. The moment a
# spec elsewhere wants "just the scaffold normalizer", the answer is to assert
# through .call, not to make a step reachable.
#
# Ingest writes nothing, so nothing here needs the database.
RSpec.describe ProblemSetIngest do
  # Runs the whole pipeline and hands back the mutated set, so a step-focused
  # example still goes through the real interface. The steps are ordered and
  # independent — no step undoes another's work — so asserting one field after
  # a full run says the same thing as calling that step alone used to.
  def step(problem_set, language: "ruby_rails")
    described_class.call(problem_set, language: language).problem_set
  rescue AiService::InvalidResponseError
    raise
  end

  def ingest(problem_set, language: "ruby_rails")
    described_class.call(problem_set, language: language)
  end

  describe ".call" do
    it "returns the cleaned problem set and the concepts it could not place" do
      result = ingest({ "code_review" => { "concept" => "not_a_real_concept" } })

      expect(result.problem_set["code_review"]["concept"]).to eq("other")
      expect(result.suggested_concepts.map(&:name)).to eq([ "not_a_real_concept" ])
      expect(result.suggested_concepts.map(&:bucket)).to eq([ "ruby_rails" ])
    end

    it "reports no suggestions when every concept is on its vocabulary" do
      result = ingest({ "code_review" => { "concept" => "n_plus_one" } })

      expect(result.suggested_concepts).to be_empty
    end

    # The guarantee that replaces the old ordering comment: a set rejected for
    # an unusable answer key cannot leave a vocabulary suggestion behind,
    # because nothing is written and the caller never receives a Result.
    it "reports nothing at all when the set is rejected" do
      set = {
        "code_review"    => { "concept" => "invented_concept" },
        "ambiguity_hunt" => { "planted_ambiguities" => [] }
      }

      expect { ingest(set) }.to raise_error(AiService::InvalidResponseError)
    end

    it "writes no SuggestedConcept rows of its own" do
      expect { ingest({ "code_review" => { "concept" => "invented_concept" } }) }
        .not_to change(SuggestedConcept, :count)
    end
  end

  describe ".vocabulary_for" do
    it "resolves each kind's vocabulary through its vocabulary_key" do
      expect(described_class.vocabulary_for("code_review", "ruby_rails")).to eq(AiService::RAILS_CONCEPTS)
      expect(described_class.vocabulary_for("code_review", "javascript")).to eq(AiService::JS_CONCEPTS)
      expect(described_class.vocabulary_for("architecture", "ruby_rails")).to eq(AiService::ARCHITECTURE_CONCEPTS)
      expect(described_class.vocabulary_for("security_review", "ruby_rails")).to eq(AiService::RAILS_SECURITY_CONCEPTS)
      expect(described_class.vocabulary_for("plan_review", "ruby_rails")).to eq(AiService::PLAN_REVIEW_CONCEPTS)
      expect(described_class.vocabulary_for("ambiguity_hunt", "ruby_rails")).to eq(AiService::AMBIGUITY_HUNT_CONCEPTS)
    end

    it "falls back to the language vocabulary for a section key a provider invented" do
      expect(described_class.vocabulary_for("made_up_section", "ruby_rails")).to eq(AiService::RAILS_CONCEPTS)
    end
  end

  describe "parsons block scrambling" do
    it "persists a display order that is a permutation of the blocks" do
      set = step({ "parsons_problem" => { "blocks" => %w[a b c d e] } })

      expect(set["parsons_problem"]["display_order"].sort).to eq([ 0, 1, 2, 3, 4 ])
    end

    it "never ships the already-solved arrangement" do
      20.times do
        set = step({ "parsons_problem" => { "blocks" => %w[a b c d e] } })
        expect(set["parsons_problem"]["display_order"]).not_to eq([ 0, 1, 2, 3, 4 ])
      end
    end

    it "leaves a single-block section alone rather than looping forever" do
      set = step({ "parsons_problem" => { "blocks" => %w[only] } })

      expect(set["parsons_problem"]["display_order"]).to eq([ 0 ])
    end

    it "ignores a parsons section with no blocks array" do
      set = step({ "parsons_problem" => { "question" => "q" } })

      expect(set["parsons_problem"]).not_to have_key("display_order")
    end
  end

    describe "the answer key"  do
      def planted(*entries)
        { "ambiguity_hunt" => { "request" => "vague", "planted_ambiguities" => entries.flatten(1) } }
      end

      def exactly_enough
        Array.new(ExerciseSection::AmbiguityHunt::PLANTED_COUNT) { |i| "ambiguity #{i}" }
      end

      it "passes a list of exactly the planted count through" do
        set = planted(exactly_enough)
        result = step(set)
        expect(result["ambiguity_hunt"]["planted_ambiguities"]).to eq(exactly_enough)
      end

      it "strips whitespace off each entry" do
        set = planted(exactly_enough.map { |a| "  #{a}\n" })
        step(set)
        expect(set["ambiguity_hunt"]["planted_ambiguities"]).to eq(exactly_enough)
      end

      it "raises when the field is missing entirely" do
        set = { "ambiguity_hunt" => { "request" => "vague" } }
        expect { step(set) }
          .to raise_error(AiService::InvalidResponseError, /no usable planted_ambiguities/)
      end

      it "raises when the field is not an array" do
        set = { "ambiguity_hunt" => { "planted_ambiguities" => "one; two; three; four" } }
        expect { step(set) }
          .to raise_error(AiService::InvalidResponseError)
      end

      it "raises when every entry is unusable" do
        set = planted([ "   ", nil, 42, "" ])
        expect { step(set) }
          .to raise_error(AiService::InvalidResponseError)
      end

      # The prompt asks for an exact count, but nothing downstream reads it: the
      # review prompt lists the ambiguities rather than counting them. Rejecting
      # a short list would discard the day's other three sections over the
      # likeliest deviation an LLM makes on a counted list.
      it "keeps a gradable list that came back short of the asked-for count" do
        set = planted(exactly_enough.first(2) + [ "  ", nil ])
        step(set)
        expect(set["ambiguity_hunt"]["planted_ambiguities"]).to eq(exactly_enough.first(2))
      end

      it "keeps a list that came back over the asked-for count, up to the ingest bound" do
        set = planted(exactly_enough + [ "one more" ])
        step(set)
        expect(set["ambiguity_hunt"]["planted_ambiguities"]).to eq(exactly_enough + [ "one more" ])
      end

      it "truncates a runaway list at AmbiguityHunt::MAX_PLANTED" do
        set = planted(Array.new(40) { |i| "ambiguity #{i}" })
        step(set)
        expect(set["ambiguity_hunt"]["planted_ambiguities"].size).to eq(ExerciseSection::AmbiguityHunt::MAX_PLANTED)
      end

      it "does nothing for a problem set with no ambiguity_hunt section" do
        set = { "plan_review" => { "plan_excerpt" => "a plan" } }
        expect { step(set) }.not_to raise_error
      end

      # plan_review wins the fourth slot when both shapes come back, so the
      # ambiguity hunt's answer key is never read — discarding the day's other
      # three sections over it would be strictly worse than ignoring it.
      it "ignores an unusable list on an ambiguity_hunt that lost the fourth slot to plan_review" do
        set = {
          "plan_review"    => { "plan_excerpt" => "a plan" },
          "ambiguity_hunt" => { "request" => "vague" }
        }

        expect { step(set) }.not_to raise_error
      end
    end


    describe "concepts" do
      it "keeps on-list concepts and maps off-list ones to 'other'" do
        set = {
          "code_review" => { "concept" => "n_plus_one" },
          "pattern" => { "concept" => "N+1 Queries!!" },
          "challenge" => { "question" => "no concept key" }
        }
        out = step(set)
        expect(out["code_review"]["concept"]).to eq("n_plus_one")
        expect(out["pattern"]["concept"]).to eq("other")
        expect(out["challenge"]).not_to have_key("concept")
      end

      it "validates against the JS vocabulary when language is javascript" do
        set = {
          "code_review" => { "concept" => "closures" },
          "pattern" => { "concept" => "n_plus_one" }
        }
        out = step(set, language: "javascript")
        expect(out["code_review"]["concept"]).to eq("closures")
        expect(out["pattern"]["concept"]).to eq("other")
      end

      it "reports an off-list concept as a suggestion in the day's bucket" do
        result = ingest({ "pattern" => { "concept" => "N+1 Queries!!" } })

        expect(result.suggested_concepts.size).to eq(1)
        expect(result.suggested_concepts.first.bucket).to eq("ruby_rails")
        expect(result.suggested_concepts.first.name).to eq("N+1 Queries!!")
      end

      it "reports no suggestion for an on-list concept" do
        expect(ingest({ "code_review" => { "concept" => "n_plus_one" } }).suggested_concepts).to be_empty
      end

      it "reports no suggestion for a section with no concept key" do
        expect(ingest({ "challenge" => { "question" => "no concept key" } }).suggested_concepts).to be_empty
      end

      it "validates the architecture section against ARCHITECTURE_CONCEPTS regardless of language" do
        set = {
          "code_review"  => { "concept" => "n_plus_one" },
          "architecture" => { "concept" => "service_boundaries" }
        }
        out = step(set, language: "javascript")
        expect(out["architecture"]["concept"]).to eq("service_boundaries")   # in arch vocab, kept
        expect(out["code_review"]["concept"]).to eq("other")                 # not in JS vocab
      end

      it "maps an off-list architecture concept to 'other' and reports it under the 'architecture' bucket" do
        set = { "architecture" => { "concept" => "Microservices Everywhere!!" } }

        result = ingest(set, language: "ruby_rails")

        expect(result.problem_set["architecture"]["concept"]).to eq("other")
        expect(result.suggested_concepts.map(&:bucket)).to eq([ "architecture" ])
      end

      it "does not treat a Rails concept as valid in the architecture section" do
        set = { "architecture" => { "concept" => "n_plus_one" } }
        out = step(set, language: "ruby_rails")
        expect(out["architecture"]["concept"]).to eq("other")
      end

      it "validates the security_review section against that language's security_concepts, not the full vocabulary" do
        set = {
          "code_review"     => { "concept" => "memoization" },
          "security_review" => { "concept" => "sql_injection_prevention" }
        }
        out = step(set, language: "ruby_rails")
        expect(out["code_review"]["concept"]).to eq("memoization")
        expect(out["security_review"]["concept"]).to eq("sql_injection_prevention")
      end

      it "maps an on-language-vocabulary but off-security-list concept in security_review to 'other'" do
        set = { "security_review" => { "concept" => "memoization" } }
        result = ingest(set, language: "ruby_rails")

        expect(result.problem_set["security_review"]["concept"]).to eq("other")
        expect(result.suggested_concepts.map(&:bucket)).to eq([ "ruby_rails" ])
      end
    end


    describe "concepts in the fourth-slot vocabularies" do
      it "keeps a valid plan_review concept and buckets suggestions under plan_review" do
        set = { "plan_review" => { "concept" => "scope_creep" } }
        result = step(set, language: "ruby_rails")
        expect(result["plan_review"]["concept"]).to eq("scope_creep")
      end

      it "normalizes an off-vocabulary plan_review concept to other" do
        set = { "plan_review" => { "concept" => "n_plus_one" } } # a RAILS_CONCEPTS entry, not plan_review's
        result = step(set, language: "ruby_rails")
        expect(result["plan_review"]["concept"]).to eq("other")
      end

      # Reached through .call, so the answer-key check runs first: an
      # ambiguity_hunt fixture needs a usable planted list or the set is
      # rejected before its concept is ever looked at.
      it "keeps a valid ambiguity_hunt concept regardless of the day's language" do
        set = { "ambiguity_hunt" => { "concept" => "missing_success_criteria",
                                      "planted_ambiguities" => [ "a gap" ] } }
        result = step(set, language: "javascript")
        expect(result["ambiguity_hunt"]["concept"]).to eq("missing_success_criteria")
      end
    end


    describe "answer scaffolds" do
      it "keeps a usable scaffold on a scaffolded section" do
        set = { "pattern" => { "answer_scaffold" => [ "  Your approach:  ", "What breaks:" ] } }

        expect(step(set)["pattern"]["answer_scaffold"])
          .to eq([ "Your approach:", "What breaks:" ])
      end

      it "bounds a scaffold the model let run long or wide" do
        set = { "architecture" => { "answer_scaffold" => (1..9).map { |i| "L#{i}: " + "x" * 200 } } }

        labels = step(set)["architecture"]["answer_scaffold"]
        expect(labels.size).to eq(ExerciseSection::MAX_SCAFFOLD_LABELS)
        expect(labels.map(&:length)).to all(be <= ExerciseSection::MAX_SCAFFOLD_LABEL_LENGTH)
      end

      # Dropped rather than repaired: the reader then takes the same fallback path
      # every pre-scaffold row already takes.
      it "drops an unusable scaffold instead of persisting it" do
        [ "not an array", [], [ "", nil ], [ 42, true ], 42 ].each do |bad|
          set = { "pattern" => { "question" => "q", "answer_scaffold" => bad } }
          expect(step(set)["pattern"]).not_to have_key("answer_scaffold")
        end
      end

      it "strips a scaffold the model volunteered for an unscaffolded section" do
        set = { "code_review" => { "answer_scaffold" => [ "Nope:" ] } }

        expect(step(set)["code_review"]).not_to have_key("answer_scaffold")
      end

      it "leaves a section that carries no scaffold alone" do
        set = { "pattern" => { "question" => "q" } }

        expect(step(set)).to eq("pattern" => { "question" => "q" })
      end
    end


    describe "diagrams" do
      it "keeps a usable diagram on a diagrammable section" do
        set = { "code_review" => { "diagram" => "  flowchart TD\n  A[Job] --> B[(DB)]  " } }

        expect(step(set)["code_review"]["diagram"])
          .to eq("flowchart TD\n  A[Job] --> B[(DB)]")
      end

      # Dropped rather than truncated: a half a diagram is broken Mermaid, which
      # the renderer rejects anyway — dropping says the same thing without the
      # CDN round trip.
      it "drops an unusable diagram instead of persisting it" do
        [ "", "   ", nil, 42, [ "flowchart TD" ], "x" * (ProblemSetIngest::MAX_DIAGRAM_LENGTH + 1) ].each do |bad|
          set = { "pattern" => { "question" => "q", "diagram" => bad } }
          expect(step(set)["pattern"]).not_to have_key("diagram")
        end
      end

      it "strips a diagram the model volunteered for a non-diagrammable section" do
        set = { "security_review" => { "diagram" => "flowchart TD\n  A --> B" } }

        expect(step(set)["security_review"]).not_to have_key("diagram")
      end

      # Architecture's diagram lives at reference.diagram, not at the top level,
      # and predates this field — normalizing the top level must not reach into
      # it.
      it "leaves architecture's existing reference diagram untouched" do
        set = { "architecture" => { "reference" => { "diagram" => "flowchart TD\n  A --> B" } } }

        expect(step(set)["architecture"]["reference"]["diagram"])
          .to eq("flowchart TD\n  A --> B")
      end

      it "leaves a section that carries no diagram alone" do
        set = { "pattern" => { "question" => "q" } }

        expect(step(set)).to eq("pattern" => { "question" => "q" })
      end
    end
end
