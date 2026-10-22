require "rails_helper"

# Plain callables, since the pipeline reaches a provider only through JudgedGeneration::Provider.
RSpec.describe JudgedGeneration do
  let(:draft_type) { Struct.new(:problem_set, :plan, :kinds, :difficulty, :unusable_sections, keyword_init: true) }
  let(:due_check) { Struct.new(:concept) }

  let(:user) { User.new(id: 42, skill_level: "senior") }
  let(:kinds) { [ ExerciseSection::CodeReview, ExerciseSection::Pattern, ExerciseSection::Challenge ] }
  let(:drafted) do
    {
      "code_review" => { "concept" => "n_plus_one", "question" => "What is wrong?", "snippet" => "code" },
      "pattern"     => { "concept" => "service_objects", "question" => "Which pattern?" },
      "challenge"   => { "concept" => "memoization", "question" => "Implement it" },
      "architecture" => { "concept" => "extra", "question" => "never planned" }
    }
  end
  let(:daily_kinds) { DailyKinds::DEFAULT }
  let(:plan) do
    plan_for(daily_kinds: daily_kinds, due_checks: [ due_check.new("service_objects") ], fourth_due_checks: [],
             reinforcement: [ { concept: "memoization" } ], fourth_reinforcement: nil)
  end
  let(:draft) { draft_type.new(problem_set: drafted, plan: plan, kinds: kinds, difficulty: KindDifficulty.none) }
  let(:finished) { [] }
  let(:finish) { ->(set, **logs) { finished << [ set, logs ] } }
  let(:judged_calls) { [] }
  let(:retry_calls) { [] }
  let(:verdicts) { Hash.new { |hash, key| hash[key] = [ { "status" => "keep" } ] } }
  let(:retried_sections) { {} }

  let(:providers) do
    lambda do
      JudgedGeneration::Provider.new(
        judge_section: lambda { |judged_user, kind, section, rung:, locked:|
          judged_calls << [ judged_user, kind.key, section, rung, locked ]
          reply = verdicts[kind.key].length > 1 ? verdicts[kind.key].shift : verdicts[kind.key].first
          raise reply if reply.is_a?(Exception)

          JudgeVerdict.parse(reply, kind: kind)
        },
        retry_section: lambda { |retry_draft, kind, concept|
          retry_calls << [ retry_draft, kind.key, concept ]
          reply = retried_sections.fetch(kind.key) { drafted[kind.key].merge("question" => "Retried") }
          raise reply if reply.is_a?(Exception)

          reply
        },
        judge_identity: { judge_provider: "anthropic", judge_model: "judge-model" }
      )
    end
  end

  def reject(principle = "scope_mismatch")
    { "status" => "reject", "principle" => principle, "evidence" => "quoted", "reason" => "because" }
  end

  def run = described_class.call(user: user, draft: draft, providers: providers, finish: finish)

  it "judges only planned sections, at each kind's rung, and returns the existing JudgedSet" do
    judged = run

    expect(judged).to be_a(AiService::JudgedSet)
    expect(judged.problem_set.keys).to eq(%w[code_review pattern challenge])
    expect(judged.dropped_sections).to eq([])
    expect(judged.outcomes.values).to all(include(status: :keep, retries: 0, dropped: false, fallback: nil))
    expect(judged_calls.map { |call| call[1] }).to contain_exactly("code_review", "pattern", "challenge")
    expect(judged_calls).to all(satisfy { |call| call[0] == user && call[3] == "senior" && call[4] == false })
    expect(retry_calls).to be_empty
  end

  it "retries a rejection once through the provider with the draft's kind and concept" do
    verdicts["pattern"] = [ reject, { "status" => "keep" } ]

    judged = run

    expect(retry_calls).to eq([ [ draft, "pattern", "service_objects" ] ])
    expect(judged.problem_set["pattern"]["question"]).to eq("Retried")
    expect(judged.outcomes["pattern"]).to include(status: :keep, retries: 1, principle: "scope_mismatch",
                                                  retry_principle: [ nil ], retry_issues: [ [] ])
  end

  it "drops a section rejected on its last retry and hands the finish step what it carried" do
    verdicts["pattern"] = [ reject, reject("underdetermined") ]

    judged = run

    expect(judged.dropped_sections).to eq([ "pattern" ])
    expect(judged.problem_set).not_to have_key("pattern")
    expect(judged.outcomes["pattern"]).to include(status: :reject, dropped: true, retry_principle: [ "underdetermined" ])
    set, logs = finished.sole
    expect(set).to equal(judged.problem_set)
    expect(logs).to eq(
      dropped_concepts: { "pattern" => "service_objects" }, judge: judged.outcomes,
      unhosted: [ { section: "pattern", concept: "service_objects", planned_as: "retention" } ]
    )
  end

  it "gives a fixed kind two retries and then drops it like any other" do
    verdicts["code_review"] = [ reject ]

    judged = run

    expect(retry_calls.map { |call| call[1] }).to eq(%w[code_review code_review])
    expect(judged.dropped_sections).to eq([ "code_review" ])
    expect(judged.problem_set).not_to have_key("code_review")
    expect(judged.outcomes["code_review"]).to include(dropped: true, fallback: nil, retries: 2,
                                                      retry_principle: %w[scope_mismatch scope_mismatch])
  end

  it "raises rather than write an empty day when every section is dropped" do
    kinds.each { |kind| verdicts[kind.key] = [ reject ] }
    allow(Rails.logger).to receive(:warn)

    expect { run }.to raise_error(ProviderError::AllSectionsRejectedError)
    expect(finished).to be_empty
    expect(Rails.logger).to have_received(:warn).with(/\[judge_all_rejected\] user=42/)
  end

  describe "a planned section ingest refused as unusable" do
    let(:unusable) { [ ProblemSetIngest::Unusable.new(key: "challenge", concept: "memoization", reason: "bad") ] }

    before do
      drafted.delete("challenge")
      draft.unusable_sections = unusable
    end

    it "is retried with its drafted concept, like a rejection, and ships when the retry is kept" do
      retried_sections["challenge"] = { "concept" => "memoization", "question" => "Retried" }

      judged = run

      expect(retry_calls).to eq([ [ draft, "challenge", "memoization" ] ])
      expect(judged.problem_set["challenge"]).to include("question" => "Retried")
      expect(judged.outcomes["challenge"]).to include(unusable: true, status: :keep, retries: 1, dropped: false)
    end

    it "is dropped once its retries are rejected, and named with its concept" do
      retried_sections["challenge"] = { "concept" => "memoization", "question" => "Retried" }
      verdicts["challenge"] = [ reject ]

      judged = run

      expect(judged.dropped_sections).to eq([ "challenge" ])
      expect(finished.sole.last[:dropped_concepts]).to include("challenge" => "memoization")
    end

    it "is dropped without a retry when it carried no usable concept" do
      draft.unusable_sections = [ ProblemSetIngest::Unusable.new(key: "challenge", concept: nil, reason: "bad") ]

      judged = run

      expect(retry_calls).to be_empty
      expect(judged.dropped_sections).to eq([ "challenge" ])
    end

    it "ignores an unusable section the day never planned" do
      draft.unusable_sections = [ ProblemSetIngest::Unusable.new(key: "plan_review", concept: "scope_creep", reason: "bad") ]
      drafted["challenge"] = { "concept" => "memoization", "question" => "Implement it" }

      expect(run.outcomes).not_to have_key("plan_review")
    end
  end

  it "drops a section whose retry the deadline stopped and lands the kept ones" do
    verdicts["pattern"] = [ reject, { "status" => "keep" } ]
    retried_sections["pattern"] = ProviderError::DeadlineError.new("retry_section")

    judged = run

    expect(judged.problem_set.keys).to eq(%w[code_review challenge])
    expect(judged.dropped_sections).to eq(%w[pattern])
  end

  it "drops without a retry call when the drafted concept is other" do
    drafted["challenge"]["concept"] = "other"
    verdicts["challenge"] = [ reject ]

    judged = run

    expect(retry_calls).to be_empty
    expect(judged.dropped_sections).to eq([ "challenge" ])
    expect(finished.sole.last[:unhosted]).to eq([])
  end

  it "drops a section whose retry fails, logging it instead of raising" do
    verdicts["challenge"] = [ reject ]
    retried_sections["challenge"] = ProviderError::RateLimitError.new("slow down")
    allow(Rails.logger).to receive(:warn)

    judged = run

    expect(judged.dropped_sections).to eq([ "challenge" ])
    expect(judged.outcomes["challenge"]).to include(retries: 0, dropped: true)
    expect(Rails.logger).to have_received(:warn).with(/\[judge_retry_failed\] user=42 section=challenge/)
  end

  it "keeps the draft and records the reason when the judge cannot answer" do
    verdicts["code_review"] = [ ProviderError::TimeoutError.new("slow") ]
    verdicts["pattern"]     = [ JudgeVerdict::Invalid.new("bad") ]
    verdicts["challenge"]   = [ ProviderError::RateLimitError.new("busy") ]
    allow(Rails.logger).to receive(:warn)

    judged = run

    expect(judged.problem_set.slice("code_review", "pattern", "challenge")).to eq(drafted.except("architecture"))
    expect(judged.outcomes.transform_values { |outcome| outcome[:fallback] })
      .to eq("code_review" => "timeout", "pattern" => "invalid_output", "challenge" => "rate_limit")
    expect(Rails.logger).to have_received(:warn).with(/\[judge_fallback\]/).exactly(3).times
  end

  it "records a truncated judge reply under the reason the review judge uses" do
    verdicts["code_review"] = [ ProviderError::TruncatedResponseError.new("cut off") ]
    allow(Rails.logger).to receive(:warn)

    expect(run.outcomes["code_review"][:fallback]).to eq("truncated")
  end

  it "asks the factory for a fresh provider for every judge and retry call" do
    verdicts["pattern"] = [ reject, { "status" => "keep" } ]
    built = 0
    counting = -> { built += 1; providers.call }

    described_class.call(user: user, draft: draft, providers: counting, finish: finish)

    expect(built).to eq(kinds.size + 2)
  end

  it "retries a rejected retry no further when the kind allows one" do
    verdicts["pattern"] = [ reject, reject ]

    run

    expect(retry_calls.size).to eq(1)
  end

  context "when the kind is one of the plan's daily kinds" do
    let(:daily_kinds) { [ ExerciseSection::Pattern, ExerciseSection::CodeReview ] }

    it "gives it as many retries as the plan allows a daily kind" do
      verdicts["pattern"] = [ reject, reject("underdetermined"), { "status" => "keep" } ]

      judged = run

      expect(retry_calls.map { |call| call[1] }).to eq(%w[pattern pattern])
      expect(judged.outcomes["pattern"]).to include(status: :keep, retries: 2, dropped: false)
      # One entry per judged retry, so the rejected first attempt never describes the section that shipped.
      expect(judged.outcomes["pattern"]).to include(retry_principle: [ "underdetermined", nil ],
                                                    retry_evidence: [ "quoted", nil ], retry_reason: [ "because", nil ])
    end

    it "drops a section once every retry its kind allows is rejected" do
      verdicts["pattern"] = [ reject, reject, reject("underdetermined") ]

      judged = run

      expect(retry_calls.size).to eq(2)
      expect(judged.outcomes["pattern"]).to include(retries: 2, dropped: true, retry_principle: %w[scope_mismatch underdetermined])
    end
  end

  # The diagnostics log serializes these hashes, so key order is part of the log line.
  describe "the outcome a rejection leaves" do
    def outcome_for(*pattern_verdicts)
      verdicts["pattern"] = pattern_verdicts
      run.outcomes["pattern"]
    end

    it "lists a dropped section's fields in the order the log has always written them" do
      outcome = outcome_for(reject, reject("underdetermined"))

      expect(outcome.keys).to eq(%i[status issues principle retries dropped fallback latency_ms evidence reason
                                    retry_principle retry_issues retry_evidence retry_reason])
      expect(outcome.except(:latency_ms)).to eq(
        status: :reject, issues: [], principle: "scope_mismatch", retries: 1, dropped: true, fallback: nil,
        evidence: "quoted", reason: "because", retry_principle: [ "underdetermined" ], retry_issues: [ [] ],
        retry_evidence: [ "quoted" ], retry_reason: [ "because" ]
      )
    end

    it "lists a kept retry's fields in the same order" do
      outcome = outcome_for(reject, { "status" => "keep" })

      expect(outcome.keys).to eq(%i[status issues principle retries dropped fallback latency_ms evidence reason
                                    retry_principle retry_issues retry_evidence retry_reason])
      expect(outcome.except(:latency_ms)).to eq(
        status: :keep, issues: [], principle: "scope_mismatch", retries: 1, dropped: false, fallback: nil,
        evidence: "quoted", reason: "because", retry_principle: [ nil ], retry_issues: [ [] ],
        retry_evidence: [ nil ], retry_reason: [ nil ]
      )
    end

    it "lists a re-judge fallback's fields in the same order" do
      allow(Rails.logger).to receive(:warn)
      outcome = outcome_for(reject, ProviderError::TimeoutError.new("slow"))

      expect(outcome.keys).to eq(%i[status issues principle retries dropped fallback latency_ms evidence reason
                                    retry_principle retry_issues retry_evidence retry_reason])
      expect(outcome.except(:latency_ms)).to eq(
        status: :keep, issues: [], principle: "scope_mismatch", retries: 1, dropped: false, fallback: "timeout",
        evidence: "quoted", reason: "because", retry_principle: [ nil ], retry_issues: [ [] ],
        retry_evidence: [ nil ], retry_reason: [ nil ]
      )
    end

    it "drops a retry whose re-judge the deadline stopped, and starts no further retry" do
      allow(Rails.logger).to receive(:warn)
      outcome = outcome_for(reject, ProviderError::DeadlineError.new("judge_section"))

      expect(retry_calls.size).to eq(1)
      expect(outcome.keys).to eq(%i[status issues principle retries dropped fallback latency_ms evidence reason
                                    retry_principle retry_issues retry_evidence retry_reason])
      expect(outcome.except(:latency_ms)).to eq(
        status: :reject, issues: [], principle: "scope_mismatch", retries: 1, dropped: true, fallback: "deadline",
        evidence: "quoted", reason: "because", retry_principle: [ nil ], retry_issues: [ [] ],
        retry_evidence: [ nil ], retry_reason: [ nil ]
      )
    end

    it "lists a failed retry's fields in the same order" do
      allow(Rails.logger).to receive(:warn)
      retried_sections["pattern"] = ProviderError::RateLimitError.new("slow down")
      outcome = outcome_for(reject)

      expect(outcome.keys).to eq(%i[status issues principle retries dropped fallback latency_ms evidence reason
                                    retry_principle retry_issues retry_evidence retry_reason])
      expect(outcome.except(:latency_ms)).to eq(
        status: :reject, issues: [], principle: "scope_mismatch", retries: 0, dropped: true, fallback: nil,
        evidence: "quoted", reason: "because", retry_principle: [], retry_issues: [],
        retry_evidence: [], retry_reason: []
      )
    end
  end

  it "leaves the draft's own problem set untouched" do
    verdicts["pattern"] = [ reject, reject ]

    expect { run }.not_to change { drafted.deep_dup }
  end

  describe "a section the judge solves blind" do
    let(:kinds) { [ ExerciseSection::CodeReview, ExerciseSection::DesignComparison ] }
    let(:drafted) do
      {
        "code_review" => { "concept" => "n_plus_one", "question" => "What is wrong?", "snippet" => "code" },
        "design_comparison" => { "concept" => "open_closed", "question" => "Which fits?", "piece_a" => "a", "piece_b" => "b",
                                 "answer_key" => { "better" => "b", "deciding_fact" => "SECRET fact",
                                                   "principle" => "SECRET principle", "why_other_fails" => "SECRET cost" } }
      }
    end
    let(:logged) { [] }

    before { allow(Rails.logger).to receive(:warn) { |message| logged << message } }

    def solve(status, better)
      { "status" => status, "better" => better }
    end

    it "records an agreeing solve without logging a mismatch" do
      verdicts["design_comparison"] = [ solve("keep", "b") ]

      expect(run.outcomes["design_comparison"]).to include(solve_matched: [ true ], status: :keep)
      expect(logged.grep(/judge_solve_mismatch/)).to be_empty
    end

    # JudgeVerdict never quotes the solve (judge_verdict_spec), while a provider error's body can echo the section.
    it "logs a refused verdict's message, and only the reason code for any other judge failure" do
      verdicts["design_comparison"] = [ JudgeVerdict::Invalid.new('unknown status "maybe"') ]
      verdicts["code_review"] = [ ProviderError::TimeoutError.new("SECRET body echo") ]

      judged = run

      expect(judged.outcomes["design_comparison"]).to include(fallback: "invalid_output")
      expect(logged.grep(/judge_fallback/)).to contain_exactly(
        '[judge_fallback] user=42 section=design_comparison reason=invalid_output: unknown status "maybe"',
        "[judge_fallback] user=42 section=code_review reason=timeout"
      )
    end

    it "logs a mismatch with the rung only, and lets the verdict stand while rejection is off" do
      verdicts["design_comparison"] = [ solve("keep", "a") ]

      judged = run

      expect(judged.outcomes["design_comparison"]).to include(solve_matched: [ false ], status: :keep)
      expect(judged.problem_set).to have_key("design_comparison")
      line = logged.grep(/judge_solve_mismatch/).sole
      expect(line).to eq("[judge_solve_mismatch] user=42 section=design_comparison rung=senior")
      expect(described_class::REJECT_SOLVE_MISMATCH_BELOW_PRINCIPAL).to be(false)
    end

    it "rejects a mismatch as underdetermined below principal once the switch is on" do
      stub_const("#{described_class}::REJECT_SOLVE_MISMATCH_BELOW_PRINCIPAL", true)
      verdicts["design_comparison"] = [ solve("keep", "a"), solve("keep", "b") ]

      judged = run

      expect(judged.outcomes["design_comparison"]).to include(principle: "underdetermined", retries: 1, status: :keep,
                                                              solve_matched: [ false, true ])
    end

    it "never rejects a mismatch at principal_engineer, switch or not" do
      stub_const("#{described_class}::REJECT_SOLVE_MISMATCH_BELOW_PRINCIPAL", true)
      draft.difficulty = KindDifficulty.new(levels: { "design_comparison" => "principal_engineer" }, locked: [])
      verdicts["design_comparison"] = [ solve("keep", "a") ]

      expect(run.outcomes["design_comparison"]).to include(status: :keep, retries: 0)
    end

    it "keeps the judge's evidence and reason, and the key, out of the outcome" do
      verdicts["design_comparison"] = [ solve("reject", "a").merge("principle" => "reasoning_failure",
                                                                    "evidence" => "SECRET quote", "reason" => "SECRET why"),
                                        solve("keep", "b") ]

      outcome = run.outcomes["design_comparison"]

      expect(outcome).not_to include(:evidence, :reason, :retry_evidence, :retry_reason)
      expect(outcome.to_s).not_to include("SECRET", "better")
      expect(logged.join).not_to include("SECRET")
    end

    describe "an edit, judged once more" do
      def edit_verdict(better: "b")
        solve("edit", better).merge("issues" => [ { "type" => "padding", "evidence" => "x" } ],
                                    "fields" => { "question" => "Edited question?" })
      end

      it "ships the edit when the second judgment keeps it and solves it to the key" do
        verdicts["design_comparison"] = [ edit_verdict, solve("keep", "b") ]

        judged = run

        expect(judged.problem_set["design_comparison"]["question"]).to eq("Edited question?")
        expect(judged.outcomes["design_comparison"]).to include(status: :edit, edit_reverted: false, solve_matched: [ true, true ])
        expect(judged_calls.count { |call| call[1] == "design_comparison" }).to eq(2)
      end

      it "ships the unedited draft when the second judgment rejects the edit" do
        verdicts["design_comparison"] = [ edit_verdict, solve("reject", "b").merge("principle" => "underdetermined",
                                                                                   "evidence" => "x", "reason" => "r") ]

        judged = run

        expect(judged.problem_set["design_comparison"]["question"]).to eq("Which fits?")
        expect(judged.outcomes["design_comparison"]).to include(edit_reverted: true, dropped: false)
      end

      it "ships the unedited draft when the edited section's solve mismatches the key" do
        verdicts["design_comparison"] = [ edit_verdict, solve("keep", "a") ]

        expect(run.outcomes["design_comparison"]).to include(edit_reverted: true, solve_matched: [ true, false ])
      end

      it "ships the unedited draft when the second judgment cannot answer" do
        verdicts["design_comparison"] = [ edit_verdict, ProviderError::TimeoutError.new("slow") ]

        judged = run

        expect(judged.problem_set["design_comparison"]["question"]).to eq("Which fits?")
        expect(judged.outcomes["design_comparison"]).to include(edit_reverted: true, solve_matched: [ true ])
      end

      it "makes no second call for a kind whose edits are not re-judged" do
        verdicts["code_review"] = [ { "status" => "edit", "issues" => [ { "type" => "padding", "evidence" => "x" } ],
                                      "fields" => { "question" => "Edited" } } ]

        judged = run

        expect(judged_calls.count { |call| call[1] == "code_review" }).to eq(1)
        expect(judged.outcomes["code_review"]).not_to have_key(:edit_reverted)
      end
    end

    describe "the solves it hands back" do
      let(:comparison) { drafted["design_comparison"] }

      def edit_of(better)
        solve("edit", better).merge("issues" => [ { "type" => "padding", "evidence" => "x" } ], "fields" => { "question" => "Edited question?" })
      end

      def rejection(better = "b")
        solve("reject", better).merge("principle" => "underdetermined", "evidence" => "x", "reason" => "r")
      end

      def visibility(solves) = solves.map { |each| [ each.attempt, each.edit_check, each.shipped, each.never_shown_reason ] }

      it "answers every field JudgeSolve.record! reads" do
        expect(JudgedGeneration::Solve.members).to include(*JudgeSolve::SOLVE_FIELDS)
      end

      it "records a matched draft that shipped as one shipped solve, with the section as judged and its key" do
        verdicts["design_comparison"] = [ solve("keep", "b") ]

        judged = run

        expect(judged.solves.sole).to have_attributes(
          section: "design_comparison", attempt: 0, edit_check: false, rung: "senior", locked: false, concept: "open_closed",
          judged_section: comparison, judge_status: "keep", judge_pick: "b", key_better: "b", matched: true,
          unsolved_reason: nil, unsolved_detail: nil, edit_reverted: false, revert_reason: nil,
          judge_provider: "anthropic", judge_model: "judge-model", shipped: true, never_shown_reason: nil
        )
        expect(judged.solves.sole.judged_section).to include("answer_key" => include("better" => "b"))
      end

      it "records a mismatched draft that shipped as shipped and unmatched" do
        verdicts["design_comparison"] = [ solve("keep", "a") ]

        expect(run.solves.sole).to have_attributes(judge_pick: "a", matched: false, shipped: true, never_shown_reason: nil)
      end

      it "records no solve for a kind the judge does not solve" do
        verdicts["code_review"] = [ reject ]

        expect(run.solves.map(&:section)).to all(eq("design_comparison"))
      end

      it "ships the edit check of a kept edit, and gives the pre-edit draft no reason since its key shipped" do
        verdicts["design_comparison"] = [ edit_of("b"), solve("keep", "b") ]

        solves = run.solves

        expect(visibility(solves)).to eq([ [ 0, false, false, nil ], [ 0, true, true, nil ] ])
        expect(solves.last).to have_attributes(edit_reverted: false, revert_reason: nil)
        expect(solves.last.judged_section).to include("question" => "Edited question?", "answer_key" => comparison["answer_key"])
        expect(solves.first.judged_section).to eq(comparison)
      end

      {
        "solve_mismatch" => -> { solve("keep", "a") },
        "judge_rejected" => -> { rejection },
        "judge_failed"   => -> { ProviderError::TimeoutError.new("slow") }
      }.each do |reason, check|
        it "ships the pre-edit draft of an edit reverted for #{reason}, and records the edit check unshipped with no reason" do
          verdicts["design_comparison"] = [ edit_of("b"), instance_exec(&check) ]

          solves = run.solves

          expect(visibility(solves)).to eq([ [ 0, false, true, nil ], [ 0, true, false, nil ] ])
          expect(solves.last).to have_attributes(edit_reverted: true, revert_reason: reason)
          expect(solves.last.judged_section["question"]).to eq("Edited question?")
        end
      end

      it "records a judge that failed on the edit check with no pick" do
        verdicts["design_comparison"] = [ edit_of("b"), ProviderError::TimeoutError.new("slow") ]

        expect(run.solves.last).to have_attributes(judge_status: nil, judge_pick: nil, matched: nil, unsolved_reason: "timeout")
      end

      it "marks a rejected draft replaced by the retry that shipped" do
        verdicts["design_comparison"] = [ rejection, solve("keep", "b") ]

        solves = run.solves

        expect(visibility(solves)).to eq([ [ 0, false, false, "replaced_by_retry" ], [ 1, false, true, nil ] ])
        expect(solves.last.judged_section["question"]).to eq("Retried")
      end

      it "marks every attempt of a section whose retries were all rejected as dropped" do
        verdicts["design_comparison"] = [ rejection ]

        judged = run

        expect(judged.dropped_sections).to eq([ "design_comparison" ])
        expect(visibility(judged.solves)).to eq([ [ 0, false, false, "section_dropped" ], [ 1, false, false, "section_dropped" ],
                                                  [ 2, false, false, "section_dropped" ] ])
      end

      it "marks a retry whose re-judge the deadline stopped as dropped, with the draft" do
        verdicts["design_comparison"] = [ rejection, ProviderError::DeadlineError.new("judge_section") ]

        solves = run.solves

        expect(visibility(solves)).to eq([ [ 0, false, false, "section_dropped" ], [ 1, false, false, "section_dropped" ] ])
        expect(solves.last).to have_attributes(unsolved_reason: "deadline", judge_pick: nil)
      end

      it "marks the draft dropped when its retry could not be generated" do
        verdicts["design_comparison"] = [ rejection ]
        retried_sections["design_comparison"] = ProviderError::RateLimitError.new("busy")

        expect(visibility(run.solves)).to eq([ [ 0, false, false, "section_dropped" ] ])
      end

      it "ships a draft the judge could not answer, with no pick and the refusal message kept" do
        verdicts["design_comparison"] = [ JudgeVerdict::Invalid.new('unknown status "maybe"') ]

        expect(run.solves.sole).to have_attributes(
          shipped: true, never_shown_reason: nil, judge_status: nil, judge_pick: nil, matched: nil, key_better: "b",
          unsolved_reason: "invalid_output", unsolved_detail: 'unknown status "maybe"'
        )
      end

      it "keeps no detail for a judge failure that is not a refused verdict" do
        verdicts["design_comparison"] = [ ProviderError::TimeoutError.new("SECRET body echo") ]

        expect(run.solves.sole).to have_attributes(shipped: true, unsolved_reason: "timeout", unsolved_detail: nil)
      end

      it "records the rejection the mismatch switch makes as a draft the retry replaced" do
        stub_const("#{described_class}::REJECT_SOLVE_MISMATCH_BELOW_PRINCIPAL", true)
        verdicts["design_comparison"] = [ solve("keep", "a"), solve("keep", "b") ]

        expect(visibility(run.solves)).to eq([ [ 0, false, false, "replaced_by_retry" ], [ 1, false, true, nil ] ])
      end

      it "decides shipped from what the run kept, so a field stamped on the shipped section afterwards changes nothing" do
        verdicts["design_comparison"] = [ edit_of("b"), solve("keep", "b") ]
        unstamped = visibility(run.solves)
        verdicts["design_comparison"] = [ edit_of("b"), solve("keep", "b") ]
        stamping = ->(set, **) { set["design_comparison"]["stamped_after_judging"] = true }

        judged = described_class.call(user: user, draft: draft, providers: providers, finish: stamping)

        expect(judged.problem_set["design_comparison"]).to include("stamped_after_judging" => true)
        expect(visibility(judged.solves)).to eq(unstamped)
        expect(judged.solves.map(&:judged_section)).to all(satisfy { |section| !section.key?("stamped_after_judging") })
      end

      it "keeps the solves out of the outcomes and out of what the finish step is handed" do
        verdicts["design_comparison"] = [ rejection, edit_of("b"), solve("keep", "b") ]

        judged = run

        set, logs = finished.sole
        expect(judged.solves.size).to eq(3)
        expect(logs.keys).to eq(%i[dropped_concepts judge unhosted])
        expect([ judged.outcomes, logs ].to_s).not_to include("SECRET", "judged_section", "judge_pick", "Solve")
        expect(set["design_comparison"]).to eq(judged.problem_set["design_comparison"])
      end

      it "hands a retry the draft, the kind and the concept, never the section the judge rejected" do
        verdicts["design_comparison"] = [ rejection, rejection, solve("keep", "b") ]
        received = []
        retrying = lambda do
          providers.call.with(retry_section: lambda { |retry_draft, kind, concept|
            received << [ retry_draft, kind, concept ]
            comparison.merge("question" => "Retry #{received.size}", "piece_a" => "REJECTED-RETRY-#{received.size}")
          })
        end

        described_class.call(user: user, draft: draft, providers: retrying, finish: finish)

        expect(received.map(&:first)).to all(equal(draft))
        expect(received.map { |call| call.drop(1) }).to eq([ [ ExerciseSection::DesignComparison, "open_closed" ] ] * 2)
        expect(draft.problem_set).to eq(drafted)
        expect(received.last.inspect).not_to include("REJECTED-RETRY-1")
        expect(received.flatten).to all(satisfy { |arg| !arg.is_a?(Hash) })
      end
    end
  end
end
