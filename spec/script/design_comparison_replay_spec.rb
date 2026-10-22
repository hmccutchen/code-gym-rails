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
                                    "cost bound: at most $0.06 (3 judge calls at $0.019 each)")
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

    it "records a failed call as unsolved and carries on with the next section" do
      first = exercise_on(Date.current - 1)
      second = exercise_on(Date.current)
      judge_replies << ->(_section) { raise JudgeVerdict::Invalid, "unknown status \"maybe\"" }
      judge_replies << ->(_section) { raise ProviderError::RateLimitError, "SECRET_PROVIDER_BODY" }

      replay.run

      expect(first.judge_solves.sole).to have_attributes(source: "replay", matched: nil, judge_pick: nil, judge_status: nil,
                                                         unsolved_reason: "invalid_output",
                                                         unsolved_detail: "unknown status \"maybe\"", shipped: true)
      expect(second.judge_solves.sole).to have_attributes(matched: nil, unsolved_reason: "rate_limit", unsolved_detail: nil)
      expect(out.string).to include("unsolved (invalid_output)", "unsolved (rate_limit)", "recorded 2 (0 solved, 2 unsolved)")
      expect(out.string).not_to include("maybe")
      expect_no_section_text
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
      replay.synthesize(user.id, 8)

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

      replay.synthesize(user.id, 2)

      expect(JudgeSolve.count).to eq(1)
      expect(out.string).to include("[1/2] junior", "no section drafted, nothing recorded", "recorded 1 (1 solved, 0 unsolved)")
    end

    it "aborts before any call when no key is set" do
      expect { replay(key: nil).synthesize(user.id, 2) }.to raise_error(described_class::MissingKey)
      expect(drafts).to be_empty
      expect(JudgeSolve.count).to eq(0)
    end
  end
end
