require "rails_helper"

# Specced against plain callables rather than a provider subclass: the pipeline
# reaches a provider only through JudgedGeneration::Provider, so these examples
# pin that interface as well as the keep, retry, drop and fallback rules.
RSpec.describe JudgedGeneration do
  let(:draft_type) { Struct.new(:problem_set, :plan, :kinds, :difficulty, keyword_init: true) }
  let(:plan_type) { Struct.new(:due_checks, :fourth_due_checks, :reinforcement, :fourth_reinforcement, keyword_init: true) }
  let(:due_check) { Struct.new(:concept) }

  let(:user) { User.new(id: 42, skill_level: "solid") }
  let(:kinds) { [ ExerciseSection::CodeReview, ExerciseSection::Pattern, ExerciseSection::Challenge ] }
  let(:drafted) do
    {
      "code_review" => { "concept" => "n_plus_one", "question" => "What is wrong?", "snippet" => "code" },
      "pattern"     => { "concept" => "service_objects", "question" => "Which pattern?" },
      "challenge"   => { "concept" => "memoization", "question" => "Implement it" },
      "architecture" => { "concept" => "extra", "question" => "never planned" }
    }
  end
  let(:plan) do
    plan_type.new(due_checks: [ due_check.new("service_objects") ], fourth_due_checks: [],
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
        retry_section: lambda { |retry_user, language, retry_draft, kind, concept|
          retry_calls << [ retry_user, language, retry_draft, kind.key, concept ]
          reply = retried_sections.fetch(kind.key) { drafted[kind.key].merge("question" => "Retried") }
          raise reply if reply.is_a?(Exception)

          reply
        }
      )
    end
  end

  def reject(principle = "scope_mismatch")
    { "status" => "reject", "principle" => principle, "evidence" => "quoted", "reason" => "because" }
  end

  def run = described_class.call(user: user, language: "ruby_rails", draft: draft, providers: providers, finish: finish)

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

    expect(retry_calls).to eq([ [ user, "ruby_rails", draft, "pattern", "service_objects" ] ])
    expect(judged.problem_set["pattern"]["question"]).to eq("Retried")
    expect(judged.outcomes["pattern"]).to include(status: :keep, retries: 1, principle: "scope_mismatch",
                                                  retry_principle: [ nil ], retry_issues: [ [] ])
  end

  it "drops a droppable section rejected twice and hands the finish step what it carried" do
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

    expect(retry_calls.map { |call| call[3] }).to eq(%w[code_review code_review])
    expect(judged.dropped_sections).to eq([ "code_review" ])
    expect(judged.problem_set).not_to have_key("code_review")
    expect(judged.outcomes["code_review"]).to include(dropped: true, fallback: nil, retries: 2,
                                                      retry_principle: %w[scope_mismatch scope_mismatch])
  end

  it "raises rather than write an empty day when every section is dropped" do
    kinds.each { |kind| verdicts[kind.key] = [ reject ] }
    allow(Rails.logger).to receive(:warn)

    expect { run }.to raise_error(AiService::AllSectionsRejectedError)
    expect(finished).to be_empty
    expect(Rails.logger).to have_received(:warn).with(/\[judge_all_rejected\] user=42/)
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
    retried_sections["challenge"] = AiService::RateLimitError.new("slow down")
    allow(Rails.logger).to receive(:warn)

    judged = run

    expect(judged.dropped_sections).to eq([ "challenge" ])
    expect(judged.outcomes["challenge"]).to include(retries: 0, dropped: true)
    expect(Rails.logger).to have_received(:warn).with(/\[judge_retry_failed\] user=42 section=challenge/)
  end

  it "keeps the draft and records the reason when the judge cannot answer" do
    verdicts["code_review"] = [ AiService::TimeoutError.new("slow") ]
    verdicts["pattern"]     = [ JudgeVerdict::Invalid.new("bad") ]
    verdicts["challenge"]   = [ AiService::RateLimitError.new("busy") ]
    allow(Rails.logger).to receive(:warn)

    judged = run

    expect(judged.problem_set.slice("code_review", "pattern", "challenge")).to eq(drafted.except("architecture"))
    expect(judged.outcomes.transform_values { |outcome| outcome[:fallback] })
      .to eq("code_review" => "timeout", "pattern" => "invalid_output", "challenge" => "rate_limit")
    expect(Rails.logger).to have_received(:warn).with(/\[judge_fallback\]/).exactly(3).times
  end

  it "records a truncated judge reply under the reason the review judge uses" do
    verdicts["code_review"] = [ AiService::TruncatedResponseError.new("cut off") ]
    allow(Rails.logger).to receive(:warn)

    expect(run.outcomes["code_review"][:fallback]).to eq("truncated")
  end

  it "asks the factory for a fresh provider for every judge and retry call" do
    verdicts["pattern"] = [ reject, { "status" => "keep" } ]
    built = 0
    counting = -> { built += 1; providers.call }

    described_class.call(user: user, language: "ruby_rails", draft: draft, providers: counting, finish: finish)

    expect(built).to eq(kinds.size + 2)
  end

  it "retries a rejected retry no further when the kind allows one" do
    verdicts["pattern"] = [ reject, reject ]

    run

    expect(retry_calls.size).to eq(1)
  end

  it "gives a kind as many retries as its judge_retries allows" do
    allow(ExerciseSection::Pattern).to receive(:judge_retries).and_return(2)
    verdicts["pattern"] = [ reject, reject("underdetermined"), { "status" => "keep" } ]

    judged = run

    expect(retry_calls.map { |call| call[3] }).to eq(%w[pattern pattern])
    expect(judged.outcomes["pattern"]).to include(status: :keep, retries: 2, dropped: false)
    # One entry per judged retry, so the rejected first attempt never reads as
    # describing the section that shipped.
    expect(judged.outcomes["pattern"]).to include(retry_principle: [ "underdetermined", nil ],
                                                  retry_evidence: [ "quoted", nil ], retry_reason: [ "because", nil ])
  end

  it "drops a section once every retry its kind allows is rejected" do
    allow(ExerciseSection::Pattern).to receive(:judge_retries).and_return(2)
    verdicts["pattern"] = [ reject, reject, reject("underdetermined") ]

    judged = run

    expect(retry_calls.size).to eq(2)
    expect(judged.outcomes["pattern"]).to include(retries: 2, dropped: true, retry_principle: %w[scope_mismatch underdetermined])
  end

  # The diagnostics log serializes these hashes, so their keys and order are
  # part of what the log line says.
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
      outcome = outcome_for(reject, AiService::TimeoutError.new("slow"))

      expect(outcome.keys).to eq(%i[status issues principle retries dropped fallback latency_ms evidence reason
                                    retry_principle retry_issues retry_evidence retry_reason])
      expect(outcome.except(:latency_ms)).to eq(
        status: :keep, issues: [], principle: "scope_mismatch", retries: 1, dropped: false, fallback: "timeout",
        evidence: "quoted", reason: "because", retry_principle: [ nil ], retry_issues: [ [] ],
        retry_evidence: [ nil ], retry_reason: [ nil ]
      )
    end

    it "lists a failed retry's fields in the same order" do
      allow(Rails.logger).to receive(:warn)
      retried_sections["pattern"] = AiService::RateLimitError.new("slow down")
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
  end
end
