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
    described_class.call(problem_set, language: language, expected_keys: problem_set.keys).problem_set
  rescue AiService::InvalidResponseError
    raise
  end

  def ingest(problem_set, language: "ruby_rails")
    described_class.call(problem_set, language: language, expected_keys: problem_set.keys)
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

  describe ".selectable_vocabulary_for" do
    # Parsons grades by positional diff against one correct sequence, and
    # neither the data-modeling nor the meta-skill concepts are sequential —
    # see ExerciseSection::ParsonsProblem.excluded_vocabulary_keys.
    it "withholds every data-modeling concept from parsons_problem" do
      vocabulary = described_class.selectable_vocabulary_for("parsons_problem", "ruby_rails")

      expect(vocabulary).not_to include(*AiService::DATA_MODELING_CONCEPTS)
      expect(vocabulary).to include("n_plus_one")
    end

    it "withholds them in both languages" do
      %w[ruby_rails javascript].each do |language|
        expect(described_class.selectable_vocabulary_for("parsons_problem", language))
          .not_to include(*AiService::DATA_MODELING_CONCEPTS)
      end
    end

    # The exclusion is exactly those four groups and nothing else: parsons
    # ends up with the same list every other language-bucket kind gets, minus
    # them.
    it "changes nothing about parsons beyond the exclusion" do
      excluded = AiService::DATA_MODELING_CONCEPTS + AiService::META_SKILL_CONCEPTS +
                 AiService::CODE_SMELL_CONCEPTS + AiService::OO_DESIGN_CONCEPTS

      %w[ruby_rails javascript].each do |language|
        expect(described_class.selectable_vocabulary_for("parsons_problem", language))
          .to eq(described_class.selectable_vocabulary_for("challenge", language) - excluded)
      end
    end

    it "leaves every other kind's selectable vocabulary alone" do
      %w[pattern challenge security_review architecture plan_review ambiguity_hunt].each do |key|
        expect(described_class.selectable_vocabulary_for(key, "ruby_rails"))
          .to eq(described_class.vocabulary_for(key, "ruby_rails")), "#{key} was narrowed unexpectedly"
      end
    end

    it "still narrows code_review by its content mode" do
      expect(described_class.selectable_vocabulary_for("code_review", "ruby_rails", mode: :schema_review))
        .to eq(AiService::DATA_MODELING_CONCEPTS)
    end

    it "withholds every meta-skill concept from parsons_problem in both languages" do
      %w[ruby_rails javascript].each do |language|
        expect(described_class.selectable_vocabulary_for("parsons_problem", language))
          .not_to include(*AiService::META_SKILL_CONCEPTS)
      end
    end

    # The three kinds that draw the day's full language vocabulary are the only
    # hosts these concepts can ever have: every other kind draws a disjoint
    # vocabulary of its own, so it is excluded without anyone writing an
    # exclusion (see the design doc, question 2).
    it "offers the meta-skill concepts to code_review, pattern, and challenge" do
      %w[ruby_rails javascript].each do |language|
        %w[pattern challenge].each do |key|
          expect(described_class.selectable_vocabulary_for(key, language))
            .to include(*AiService::META_SKILL_CONCEPTS), "#{key}/#{language} was missing the group"
        end

        %i[application_code test_file].each do |mode|
          expect(described_class.selectable_vocabulary_for("code_review", language, mode: mode))
            .to include(*AiService::META_SKILL_CONCEPTS)
        end
      end
    end

    it "withholds them from the kinds whose own vocabulary is disjoint" do
      %w[security_review architecture plan_review ambiguity_hunt].each do |key|
        expect(described_class.selectable_vocabulary_for(key, "ruby_rails"))
          .not_to include(*AiService::META_SKILL_CONCEPTS), "#{key} could be offered a meta-skill concept"
      end
    end

    it "withholds code smells from parsons_problem, whose format has nothing to recognize" do
      vocabulary = described_class.selectable_vocabulary_for("parsons_problem", "ruby_rails")

      expect(vocabulary).not_to include(*AiService::CODE_SMELL_CONCEPTS)
    end

    it "offers code smells to code_review outside schema-review mode" do
      vocabulary = described_class.selectable_vocabulary_for("code_review", "ruby_rails", mode: :application_code)

      expect(vocabulary).to include(*AiService::CODE_SMELL_CONCEPTS)
    end

    it "withholds code smells from a schema-review code_review" do
      vocabulary = described_class.selectable_vocabulary_for("code_review", "ruby_rails", mode: :schema_review)

      expect(vocabulary).not_to include(*AiService::CODE_SMELL_CONCEPTS)
    end

    it "withholds OO design principles from parsons_problem, whose grade is an ordering" do
      vocabulary = described_class.selectable_vocabulary_for("parsons_problem", "ruby_rails")

      expect(vocabulary).not_to include(*AiService::OO_DESIGN_CONCEPTS)
    end

    it "offers OO design principles to code_review outside schema-review mode" do
      vocabulary = described_class.selectable_vocabulary_for("code_review", "javascript", mode: :application_code)

      expect(vocabulary).to include(*AiService::OO_DESIGN_CONCEPTS)
    end

    it "withholds OO design principles from a schema-review code_review" do
      vocabulary = described_class.selectable_vocabulary_for("code_review", "ruby_rails", mode: :schema_review)

      expect(vocabulary).not_to include(*AiService::OO_DESIGN_CONCEPTS)
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

    # The asymmetry that matters: generation declines to ASK parsons for a
    # data-modeling concept, but if one arrives anyway it is a real tag and is
    # kept. Rewriting it to "other" would destroy history over a preference.
    it "still accepts a data-modeling concept tagged on parsons_problem" do
      expect(described_class.vocabulary_for("parsons_problem", "ruby_rails")).to include("missing_index")

      result = described_class.call({ "parsons_problem" => { "concept" => "missing_index" } }, language: "ruby_rails",
                                     expected_keys: %w[parsons_problem])

      expect(result.problem_set["parsons_problem"]["concept"]).to eq("missing_index")
      expect(result.suggested_concepts).to be_empty
    end

    it "falls back to the language vocabulary for a section key a provider invented" do
      expect(described_class.vocabulary_for("made_up_section", "ruby_rails")).to eq(AiService::RAILS_CONCEPTS)
    end

    # Ingest validates a persisted set and does not know which mode produced
    # it, so it passes no mode and gets the full list. The narrowing exists to
    # steer generation, not to reject a concept after the fact.
    it "returns the full language vocabulary for code_review with no mode" do
      expect(described_class.vocabulary_for("code_review", "ruby_rails"))
        .to eq(AiService::RAILS_CONCEPTS)
    end

    it "narrows code_review to the data-modeling concepts on a schema-review day" do
      expect(described_class.selectable_vocabulary_for("code_review", "ruby_rails", mode: :schema_review))
        .to eq(AiService::DATA_MODELING_CONCEPTS)
    end

    it "excludes the data-modeling concepts on the other two modes" do
      %i[application_code test_file].each do |mode|
        vocabulary = described_class.selectable_vocabulary_for("code_review", "ruby_rails", mode: mode)
        expect(vocabulary).not_to include(*AiService::DATA_MODELING_CONCEPTS)
        expect(vocabulary).to include("n_plus_one")
      end
    end

    # pattern keeps the full vocabulary: it is the only section that can host
    # a data-modeling concept on a non-schema day, which keeps a due retention
    # check reachable.
    it "leaves pattern unnarrowed on every mode" do
      %i[application_code test_file schema_review].each do |mode|
        expect(described_class.selectable_vocabulary_for("pattern", "ruby_rails", mode: mode))
          .to eq(AiService::RAILS_CONCEPTS)
      end
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

  describe "the intended set as a contract" do
    let(:full_set) do
      {
        "code_review" => { "concept" => "n_plus_one" },
        "pattern"     => { "concept" => "memoization" }
      }
    end

    it "rejects a set missing an intended section, naming it" do
      expect {
        described_class.call(full_set.except("pattern"), language: "ruby_rails",
                             expected_keys: %w[code_review pattern])
      }.to raise_error(AiService::InvalidResponseError, /pattern/)
    end

    it "names every missing section, not just the first" do
      expect {
        described_class.call({}, language: "ruby_rails", expected_keys: %w[code_review pattern])
      }.to raise_error(AiService::InvalidResponseError, /code_review.*pattern/)
    end

    it "treats a non-Hash value as missing" do
      expect {
        described_class.call(full_set.merge("pattern" => "oops"), language: "ruby_rails",
                             expected_keys: %w[code_review pattern])
      }.to raise_error(AiService::InvalidResponseError, /pattern/)
    end

    it "accepts extra sections the day did not intend" do
      extra = full_set.merge("challenge" => { "concept" => "caching" })

      result = described_class.call(extra, language: "ruby_rails", expected_keys: %w[code_review pattern])

      expect(result.problem_set).to have_key("challenge")
    end

    it "warns when the provider returns a section the day did not intend" do
      extra = full_set.merge("challenge" => { "concept" => "caching" })

      expect(Rails.logger).to receive(:warn).with(/\[unrequested_sections\].*challenge/)

      described_class.call(extra, language: "ruby_rails", expected_keys: %w[code_review pattern])
    end

    it "names what was intended alongside what arrived unasked for" do
      extra = full_set.merge("challenge" => { "concept" => "caching" })

      expect(Rails.logger).to receive(:warn).with(/code_review.*pattern/)

      described_class.call(extra, language: "ruby_rails", expected_keys: %w[code_review pattern])
    end

    # Section names are provider-controlled JSON keys, so a newline in one
    # would forge a second log line if they were interpolated raw.
    it "escapes a section name rather than letting it forge a log line" do
      forged = full_set.merge("challenge\nFATAL -- : owned" => { "concept" => "caching" })

      expect(Rails.logger).to receive(:warn) do |message|
        expect(message.lines.size).to eq(1)
        expect(message).to include('challenge\\nFATAL')
      end

      described_class.call(forged, language: "ruby_rails", expected_keys: %w[code_review pattern])
    end

    it "stays quiet when the delivered set is exactly the intended one" do
      expect(Rails.logger).not_to receive(:warn)

      described_class.call(full_set, language: "ruby_rails", expected_keys: %w[code_review pattern])
    end

    it "reports a missing section rather than its unusable answer key" do
      expect {
        described_class.call(full_set, language: "ruby_rails",
                             expected_keys: %w[code_review pattern ambiguity_hunt])
      }.to raise_error(AiService::InvalidResponseError, /ambiguity_hunt/)
    end
  end
end
