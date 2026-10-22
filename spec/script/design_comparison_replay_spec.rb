require "rails_helper"
require Rails.root.join("script/design_comparison_replay")

RSpec.describe DesignComparisonReplay do
  let(:user) { User.create!(email: "replay@example.com", name: "Replay") }
  let(:other_user) { User.create!(email: "replay-other@example.com", name: "Other") }
  let(:out) { StringIO.new }
  let(:api_key) { "sk-ant-replay-runner-key" }
  let(:judged) { [] }
  let(:posted) { [] }
  let(:judge_replies) { [] }
  let(:judge_model) { ClaudeService::MODEL_FOR_PURPOSE.fetch("judge_section", ClaudeService::DEFAULT_ROUTE)[:model] }

  before do
    calls = judged
    replies = judge_replies
    allow_any_instance_of(ClaudeService).to receive(:judge_section) do |_service, _user, kind, section, rung:, locked:|
      calls << { kind: kind, section: section, rung: rung, locked: locked }
      (replies.shift || ->(_section) { JudgeVerdict.new(status: :keep, solve: "a") }).call(section)
    end
    requests = posted
    connection = Faraday.new { |f| f.adapter(:test) { |stub| stub.post(ClaudeService::API_URL) { |env| requests << env.body; [ 500, {}, "{}" ] } } }
    allow_any_instance_of(ClaudeService).to receive(:build_connection).and_return(connection)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with(JudgeSolve::APP_REVISION_ENV).and_return(nil)
  end

  def section(**overrides)
    { "title" => "SECRET_TITLE", "piece_a" => "SECRET_PIECE_A", "piece_b" => "SECRET_PIECE_B",
      "question" => "SECRET_QUESTION", "concept" => "n_plus_one", "pitched_at" => "senior",
      "answer_key" => { "better" => "a", "deciding_fact" => "SECRET_FACT", "principle" => "SECRET_PRINCIPLE",
                        "why_other_fails" => "SECRET_WHY" } }.merge(overrides.stringify_keys)
  end

  def exercise_on(date, owner: user, dropped: [], **overrides)
    DailyExercise.create!(user: owner, date: date, generated_at: Time.current, language: "ruby_rails",
                          problem_set: { "code_review" => { "question" => "q" }, "design_comparison" => section(**overrides) },
                          dropped_sections: dropped)
  end

  def replay(rejudge: false, key: api_key)
    described_class.new(api_key: key, out: out, rejudge: rejudge)
  end

  def expect_no_section_text
    expect(out.string).not_to include("SECRET", api_key)
  end

  describe "#dry_run" do
    it "counts by week and by user, prints the dates and the cost bound, and makes no call or write" do
      exercise_on(Date.new(2026, 10, 1))
      exercise_on(Date.new(2026, 10, 2))
      exercise_on(Date.new(2026, 10, 6), owner: other_user)

      expect { replay(key: nil).dry_run }.not_to change { [ JudgeSolve.count, ApiUsage.count, DailyExercise.count ] }

      expect(judged).to be_empty
      expect(posted).to be_empty
      expect(out.string).to include("design comparisons to judge: 3", "week of 2026-09-28: 2", "week of 2026-10-05: 1",
                                    "user #{user.id}: 2", "user #{other_user.id}: 1",
                                    "first date: 2026-10-01, last date: 2026-10-06",
                                    "worst-case bound: $0.06 (3 × $0.019 per judge call; claude-sonnet-5-5 at list price " \
                                    "with 3500 input tokens estimated and its full #{AiService::JUDGE_MAX_TOKENS}-token output cap)")
      expect_no_section_text
    end
  end

  describe "#candidates" do
    it "takes keyed sections with both pieces and a rung, and skips dropped and malformed ones" do
      kept = exercise_on(Date.current)
      exercise_on(Date.current - 1, dropped: [ "design_comparison" ])
      exercise_on(Date.current - 2, answer_key: { "better" => "c" })
      exercise_on(Date.current - 3, answer_key: {})
      exercise_on(Date.current - 4, piece_b: "")
      exercise_on(Date.current - 5, piece_a: nil)
      exercise_on(Date.current - 6, pitched_at: nil)
      exercise_on(Date.current - 7, pitched_at: "wizard")
      DailyExercise.create!(user: user, date: Date.current - 8, generated_at: Time.current, language: "ruby_rails",
                            problem_set: { "code_review" => { "question" => "q" } })

      expect(replay.candidates).to eq([ kept ])
    end
  end

  describe "#run" do
    it "judges each stored section at its rung, unlocked, and records it as a shipped replay" do
      exercise = exercise_on(Date.current, pitched_at: "mid_level")

      replay.run

      expect(judged).to contain_exactly(include(kind: ExerciseSection::DesignComparison, rung: "mid_level", locked: false,
                                                section: exercise.problem_set["design_comparison"]))
      expect(JudgeSolve.sole).to have_attributes(
        source: "replay", daily_exercise_id: exercise.id, user_id: user.id, section: "design_comparison",
        attempt: 0, edit_check: false, shipped: true, never_shown_reason: nil, edit_reverted: false,
        rung: "mid_level", locked: false, judge_pick: "a", key_better: "a", matched: true, judge_status: "keep",
        draft_model: nil, app_revision: nil, judge_provider: "anthropic", judge_model: judge_model,
        section_digest: SectionDigest.call(exercise.problem_set["design_comparison"])
      )
      expect(out.string).to include("[1/1] daily_exercise #{exercise.id}: recorded", "recorded 1 (1 solved, 0 unsolved)")
      expect_no_section_text
    end

    it "records a mismatch without printing it" do
      exercise_on(Date.current)
      judge_replies << ->(_section) { JudgeVerdict.new(status: :keep, solve: "b") }

      replay.run

      expect(JudgeSolve.sole).to have_attributes(judge_pick: "b", matched: false)
      expect(out.string).not_to include("mismatch")
    end

    it "skips a section already replayed, keyed on its digest with no app revision, and --rejudge judges it again" do
      exercise = exercise_on(Date.current)
      replay.run
      expect(JudgeSolve.sole.app_revision).to be_nil

      replay.run
      expect(judged.size).to eq(1)

      replay(rejudge: true).run
      expect(judged.size).to eq(2)
      expect(exercise.judge_solves.where(source: "replay").count).to eq(2)
    end

    it "judges again when the stored section changed since its replay" do
      exercise = exercise_on(Date.current)
      replay.run
      exercise.update!(problem_set: exercise.problem_set.deep_merge("design_comparison" => { "title" => "SECRET_NEW" }))

      replay.run

      expect(judged.size).to eq(2)
    end

    it "does not count a live record as replayed" do
      exercise = exercise_on(Date.current)
      replay.run
      JudgeSolve.where(source: "replay").update_all(source: "live")

      replay.run

      expect(judged.size).to eq(2)
      expect(exercise.judge_solves.pluck(:source)).to contain_exactly("live", "replay")
    end

    it "aborts before any call or write when no key is set" do
      exercise_on(Date.current)

      expect { replay(key: "").run }.to raise_error(described_class::MissingKey, /ANTHROPIC_API_KEY/)
      expect(judged).to be_empty
      expect(posted).to be_empty
      expect(JudgeSolve.count).to eq(0)
    end

    it "records the judge's own failures as unsolved and carries on with the next section" do
      exercises = Array.new(5) { |offset| exercise_on(Date.current - offset) }.reverse
      judge_replies << ->(_section) { raise JudgeVerdict::Invalid, "unknown status \"maybe\"" }
      judge_replies << ->(_section) { raise ProviderError::RefusalError, "SECRET_PROVIDER_BODY" }
      judge_replies << ->(_section) { raise ProviderError::TruncatedResponseError, "SECRET_PROVIDER_BODY" }
      judge_replies << ->(_section) { raise ProviderError::InvalidResponseError, "SECRET_PROVIDER_BODY" }

      replay.run

      expect(exercises.first.judge_solves.sole).to have_attributes(source: "replay", matched: nil, judge_pick: nil,
                                                                   judge_status: nil, unsolved_reason: "invalid_output",
                                                                   unsolved_detail: "unknown status \"maybe\"", shipped: true)
      expect(exercises[1..3].map { |exercise| exercise.judge_solves.sole.unsolved_reason })
        .to eq(%w[refusal truncated invalid_json])
      expect(exercises[1..3].map { |exercise| exercise.judge_solves.sole.unsolved_detail }).to all(be_nil)
      expect(exercises.last.judge_solves.sole.matched).to be(true)
      expect(out.string).to include("unsolved (invalid_output)", "unsolved (refusal)", "recorded 5 (1 solved, 4 unsolved)")
      expect(out.string).not_to include("maybe")
      expect_no_section_text
    end

    [
      [ ProviderError::BillingError, "out_of_credit" ], [ ProviderError::AuthenticationError, "authentication" ],
      [ ProviderError::RateLimitError, "rate_limit" ], [ ProviderError::TimeoutError, "timeout" ],
      [ ActiveRecord::ConnectionNotEstablished, "other" ], [ IOError, "other" ], [ SetupError, "other" ]
    ].each do |error, reason|
      it "stops on #{error.name}, records nothing for that section, and a re-run picks it up" do
        first, second, third = Array.new(3) { |offset| exercise_on(Date.current - offset) }.reverse
        judge_replies << ->(_section) { JudgeVerdict.new(status: :keep, solve: "a") }
        judge_replies << ->(_section) { raise error, "SECRET_PROVIDER_BODY" }

        replay.run

        expect(judged.size).to eq(2)
        expect(JudgeSolve.pluck(:daily_exercise_id)).to eq([ first.id ])
        expect(out.string).to include("stopped at daily_exercise #{second.id}: provider call failed (#{reason})",
                                      "1 of 3 recorded before it. Run again to continue.", "recorded 1 (1 solved, 0 unsolved)")
        expect_no_section_text

        replay.run

        expect(JudgeSolve.where(source: "replay").pluck(:daily_exercise_id)).to contain_exactly(first.id, second.id, third.id)
        expect(JudgeSolve.where(source: "replay")).to all(have_attributes(unsolved_reason: nil))
      end
    end

    it "stops with the scrubbed message and the exercise id when a record is refused" do
      first, second = Array.new(2) { |offset| exercise_on(Date.current - offset) }.reverse
      allow(JudgeSolve).to receive(:record!).and_raise(JudgeSolve::RecordError, "judge_solves row refused: judge_solves_source")

      replay.run

      expect(judged.size).to eq(1)
      expect(out.string).to include("stopped at daily_exercise #{first.id}: judge_solves row refused: judge_solves_source")
      expect(out.string).not_to include("daily_exercise #{second.id}")
    end
    it "cuts a long refusal message to the live flow's limit" do
      exercise = exercise_on(Date.current)
      judge_replies << ->(_section) { raise JudgeVerdict::Invalid, "x" * (JudgedGeneration::REFUSAL_DETAIL_LIMIT * 2) }

      replay.run

      expect(exercise.judge_solves.sole.unsolved_detail.length).to eq(JudgedGeneration::REFUSAL_DETAIL_LIMIT)
    end

    it "stamps the exercise's current set time, so the record is readable only once that set's section is reviewed" do
      exercise = exercise_on(Date.current)
      replay.run
      record = JudgeSolve.sole

      expect(record.set_generated_at).to be_within(1.second).of(exercise.generated_at)
      expect(JudgeSolve.readable).to be_empty
      DailyResponse.create!(user: user, daily_exercise: exercise, date: exercise.date, submitted_at: Time.current,
                            ai_review: { "design_comparison" => { "rating" => "solid" } })
      expect(JudgeSolve.readable).to eq([ record ])
    end
  end

  describe "#synthesize" do
    let(:drafts) { [] }

    before do
      requests = drafts
      allow_any_instance_of(ClaudeService).to receive(:retry_section) do |_service, draft, kind, concept|
        requests << { rung: draft.difficulty.rung_for(kind, skill_level: draft.user.skill_level), concept: concept }
        section(concept: concept, pitched_at: requests.last[:rung])
      end
    end

    it "spreads the sections across the rungs and the vocabulary and records them with no user or exercise" do
      replay.synthesize(user.id, 8, run: true)

      expect(drafts.map { |draft| draft[:rung] }.tally).to eq(KindDifficulty::LEVELS.index_with(2))
      KindDifficulty::LEVELS.each do |rung|
        vocabulary = ConceptVocabulary.selectable_for_section("design_comparison", user.language_for_today, rung: rung)
        concepts   = drafts.select { |draft| draft[:rung] == rung }.map { |draft| draft[:concept] }
        expect(concepts).to eq(vocabulary.first(2))
      end
      expect(JudgeSolve.count).to eq(8)
      expect(JudgeSolve.all).to all(have_attributes(source: "synthetic", user_id: nil, daily_exercise_id: nil,
                                                    set_generated_at: nil, shipped: false, never_shown_reason: nil,
                                                    locked: false, judge_provider: "anthropic",
                                                    draft_model: ClaudeService::MODEL_FOR_PURPOSE.fetch("retry_section")[:model]))
      expect(JudgeSolve.pluck(:rung).tally).to eq(KindDifficulty::LEVELS.index_with(2))
      expect_no_section_text
    end

    it "records nothing for a draft that ingest refused, and carries on" do
      allow_any_instance_of(ClaudeService).to receive(:retry_section).and_return(nil, section)

      replay.synthesize(user.id, 2, run: true)

      expect(JudgeSolve.count).to eq(1)
      expect(out.string).to include("[1/2] junior", "no section drafted, nothing recorded", "recorded 1 (1 solved, 0 unsolved)")
    end

    it "aborts before any call when no key is set" do
      expect { replay(key: nil).synthesize(user.id, 2, run: true) }.to raise_error(described_class::MissingKey)
      expect(drafts).to be_empty
      expect(JudgeSolve.count).to eq(0)
    end

    it "prints the plan by rung and the worst-case bound, and calls nothing, without --run" do
      prices      = ModelComparison::LIST_PRICE_PER_MILLION
      draft_cost  = (10_000 * prices["claude-opus-5-5"][:input] + ClaudeService::MAX_TOKENS * prices["claude-opus-5-5"][:output]) / 1e6
      judge_cost  = (3_500 * prices["claude-sonnet-5-5"][:input] + AiService::JUDGE_MAX_TOKENS * prices["claude-sonnet-5-5"][:output]) / 1e6
      per_section = draft_cost + judge_cost

      expect { replay(key: nil).synthesize(user.id, 6) }.not_to change { [ JudgeSolve.count, ApiUsage.count ] }

      expect(drafts).to be_empty
      expect(judged).to be_empty
      expect(out.string).to include("synthetic design comparisons to draft: 6 (target 6, already recorded: 0)",
                                    "rung junior: 2", "rung mid_level: 2", "rung senior: 1", "rung principal_engineer: 1",
                                    "worst-case bound: $#{format('%.2f', 6 * per_section)} " \
                                    "(6 × $#{format('%.3f', per_section)} per section; claude-opus-5-5 at list price with " \
                                    "10000 input tokens estimated and its full #{ClaudeService::MAX_TOKENS}-token output cap, " \
                                    "then claude-sonnet-5-5")
      expect(out.string.index("rung junior")).to be < out.string.index("rung principal_engineer")
    end

    it "continues the plan from the synthetic records already written" do
      replay.synthesize(user.id, 3, run: true)
      first_run = drafts.dup

      replay.synthesize(user.id, 5, run: true)

      expect(JudgeSolve.where(source: "synthetic").count).to eq(5)
      expect(drafts.drop(3).map { |draft| draft[:rung] }).to eq(%w[principal_engineer junior])
      expect(drafts.drop(3)).not_to include(*first_run)
      expect(out.string).to include("synthetic design comparisons to draft: 2 (target 5, already recorded: 3)")
    end

    it "stops on an infrastructure failure while drafting and records nothing for that slot" do
      calls = 0
      allow_any_instance_of(ClaudeService).to receive(:retry_section) do |_service, draft, kind, concept|
        calls += 1
        raise ActiveRecord::ConnectionNotEstablished if calls == 2

        section(concept: concept, pitched_at: draft.difficulty.rung_for(kind, skill_level: draft.user.skill_level))
      end

      replay.synthesize(user.id, 4, run: true)

      expect(calls).to eq(2)
      expect(JudgeSolve.count).to eq(1)
      expect(out.string).to include("stopped at mid_level", "provider call failed (other)")
    end

    it "plans and drafts on the user's own date, not the runner's" do
      user.update!(time_zone: "Pacific/Kiritimati")
      dates = []
      allow(ForcedConceptDrafts).to receive(:rung_draft).and_wrap_original do |original, *args|
        dates << Date.current
        original.call(*args)
      end
      allow(ConceptVocabulary).to receive(:selectable_for_section).and_wrap_original do |original, *args, **options|
        dates << Date.current
        original.call(*args, **options)
      end

      travel_to(Time.utc(2026, 10, 22, 12)) { replay.synthesize(user.id, 1, run: true) }

      expect(dates).to be_present
      expect(dates).to all(eq(Date.new(2026, 10, 23)))
    end
  end
end

RSpec.describe DesignComparisonReplay, "billing" do
  let(:user) { User.create!(email: "replay-billing@example.com", name: "Billing") }
  let(:seen) { [] }

  # Real connection with only the adapter swapped, so the key header is the one the service sets.
  before do
    requests = seen
    allow_any_instance_of(ClaudeService).to receive(:build_connection).and_wrap_original do |original|
      original.call.tap do |connection|
        connection.adapter :test do |stub|
          stub.post(ClaudeService::API_URL) do |env|
            requests << env.request_headers
            [ 200, {}, { "content" => [ { "type" => "text", "text" => { "status" => "keep", "better" => "a" }.to_json } ],
                         "usage" => { "input_tokens" => 70, "output_tokens" => 30 } }.to_json ]
          end
        end
      end
    end
  end

  it "bills only the runner's key and writes no usage or suggested-concept rows" do
    section = { "title" => "t", "scenario" => "s", "question" => "q", "piece_a" => "a = 1", "piece_b" => "b = 2",
                "concept" => "n_plus_one", "pitched_at" => "senior",
                "answer_key" => { "better" => "a", "deciding_fact" => "f", "principle" => "p", "why_other_fails" => "w" } }
    user.store_api_key("sk-ant-users-own-stored-key", provider: "anthropic")
    user.save!
    DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
                          problem_set: { "design_comparison" => section })
    out = StringIO.new

    expect { described_class.new(api_key: "sk-ant-runner-env-key", out: out).run }
      .not_to change { [ ApiUsage.count, SuggestedConcept.count ] }

    expect(seen.map { |headers| headers["x-api-key"] }).to eq([ "sk-ant-runner-env-key" ])
    expect(JudgeSolve.sole).to have_attributes(source: "replay", matched: true, judge_pick: "a")
    expect(out.string).to include("70 in / 30 out tokens")
  end
end
