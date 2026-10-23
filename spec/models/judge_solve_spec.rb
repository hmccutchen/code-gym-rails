require "rails_helper"

RSpec.describe JudgeSolve, type: :model do
  let(:user) { User.create!(email: "judge-solves@example.com", name: "J") }
  let(:exercise) { exercise_on(Date.current) }

  let(:section) do
    { "title" => "Two caches", "piece_a" => "a = 1", "piece_b" => "b = 2", "concept" => "caching",
      "answer_key" => { "better" => "a", "deciding_fact" => "fewer writes" } }
  end

  let(:solve_stand_in) { Data.define(*JudgeSolve::SOLVE_FIELDS) }

  def exercise_on(date)
    DailyExercise.create!(user: user, date: date, generated_at: Time.current, language: "ruby_rails",
                          problem_set: { "design_comparison" => section })
  end

  def solve(**overrides)
    solve_stand_in.new(section: "design_comparison", attempt: 0, edit_check: false, rung: "senior", locked: false,
                     concept: "caching", judged_section: section, judge_status: "keep", judge_pick: "a",
                     key_better: "a", matched: true, unsolved_reason: nil, unsolved_detail: nil,
                     edit_reverted: false, revert_reason: nil, judge_provider: "anthropic",
                     judge_model: "claude-test", shipped: true, never_shown_reason: nil, **overrides)
  end

  def row(**overrides)
    { user_id: user.id, daily_exercise_id: exercise.id, set_generated_at: exercise.generated_at, source: "live",
      section: "design_comparison", attempt: 0, edit_check: false, shipped: true, edit_reverted: false,
      rung: "senior", locked: false, key_better: "a", matched: true, judged_section: section,
      section_digest: "d", judge_provider: "anthropic", judge_model: "claude-test", created_at: Time.current }
      .merge(overrides)
  end

  def raw_insert(**overrides)
    described_class.transaction(requires_new: true) { described_class.insert_all([ row(**overrides) ]) }
  end

  def create_solve(**overrides)
    described_class.create!(row(**overrides).except(:section_digest, :created_at))
  end

  describe "check constraints" do
    it "accepts a well-formed row" do
      expect { raw_insert }.to change(described_class, :count).by(1)
    end

    it "accepts every listed source and refuses any other" do
      described_class::SOURCES.each { |source| expect { raw_insert(source: source) }.not_to raise_error }
      expect { raw_insert(source: "imported") }.to raise_error(ActiveRecord::StatementInvalid, /judge_solves_source/)
    end

    %i[user_id daily_exercise_id set_generated_at].each do |column|
      it "refuses a non-synthetic row without #{column}" do
        %w[live replay].each do |source|
          expect { raw_insert(source: source, column => nil) }
            .to raise_error(ActiveRecord::StatementInvalid, /judge_solves_owner_unless_synthetic/)
        end
      end
    end

    it "accepts a synthetic row with no user, exercise or set time" do
      expect { raw_insert(source: "synthetic", user_id: nil, daily_exercise_id: nil, set_generated_at: nil) }
        .to change(described_class, :count).by(1)
    end

    it "refuses a reverted edit without a reason" do
      expect { raw_insert(edit_check: true, shipped: false, edit_reverted: true, revert_reason: nil) }
        .to raise_error(ActiveRecord::StatementInvalid, /judge_solves_revert_reason_iff_reverted/)
    end

    it "refuses a reason on a row whose edit was not reverted" do
      expect { raw_insert(edit_reverted: false, revert_reason: "solve_mismatch") }
        .to raise_error(ActiveRecord::StatementInvalid, /judge_solves_revert_reason_iff_reverted/)
    end

    it "accepts each matched call on a matched row and refuses judge_right" do
      described_class::MATCHED_CALLS.each { |call| expect { raw_insert(matched: true, human_call: call) }.not_to raise_error }
      expect { raw_insert(matched: true, human_call: "judge_right") }
        .to raise_error(ActiveRecord::StatementInvalid, /judge_solves_human_call_by_matched/)
    end

    it "accepts each mismatch call on a mismatched row and refuses both_wrong" do
      described_class::MISMATCH_CALLS.each do |call|
        expect { raw_insert(matched: false, judge_pick: "b", human_call: call) }.not_to raise_error
      end
      expect { raw_insert(matched: false, human_call: "both_wrong") }
        .to raise_error(ActiveRecord::StatementInvalid, /judge_solves_human_call_by_matched/)
    end

    it "refuses any call on an unsolved row" do
      expect { raw_insert(matched: nil, judge_pick: nil, human_call: "key_right") }
        .to raise_error(ActiveRecord::StatementInvalid, /judge_solves_human_call_by_matched/)
    end

    it "accepts each never-shown reason on an unshipped live row" do
      described_class::NEVER_SHOWN_REASONS.each do |reason|
        expect { raw_insert(shipped: false, never_shown_reason: reason) }.not_to raise_error
      end
    end

    it "refuses an unlisted never-shown reason" do
      expect { raw_insert(shipped: false, never_shown_reason: "edit_reverted") }
        .to raise_error(ActiveRecord::StatementInvalid, /judge_solves_never_shown_reason/)
    end

    it "refuses a never-shown reason on a shipped row" do
      expect { raw_insert(shipped: true, never_shown_reason: "replaced_by_retry") }
        .to raise_error(ActiveRecord::StatementInvalid, /judge_solves_never_shown_reason/)
    end

    it "refuses a never-shown reason on a replay or synthetic row" do
      expect { raw_insert(source: "replay", shipped: false, never_shown_reason: "section_dropped") }
        .to raise_error(ActiveRecord::StatementInvalid, /judge_solves_never_shown_reason/)
      expect { raw_insert(source: "synthetic", shipped: false, never_shown_reason: "section_dropped") }
        .to raise_error(ActiveRecord::StatementInvalid, /judge_solves_never_shown_reason/)
    end
  end

  describe "the human_call validation" do
    it "offers the matched set on a matched row" do
      described_class::MATCHED_CALLS.each { |call| expect(described_class.new(matched: true, human_call: call)).to be_valid_on(:human_call) }
      expect(described_class.new(matched: true, human_call: "judge_right")).not_to be_valid_on(:human_call)
    end

    it "offers the mismatch set on a mismatched row" do
      described_class::MISMATCH_CALLS.each { |call| expect(described_class.new(matched: false, human_call: call)).to be_valid_on(:human_call) }
      expect(described_class.new(matched: false, human_call: "both_wrong")).not_to be_valid_on(:human_call)
    end

    it "offers nothing on an unsolved row" do
      expect(described_class.new(matched: nil, human_call: "key_right")).not_to be_valid_on(:human_call)
      expect(described_class.new(matched: nil, human_call: nil)).to be_valid_on(:human_call)
    end

    it "matches what the database constraint allows" do
      calls = (described_class::MATCHED_CALLS + described_class::MISMATCH_CALLS).uniq + [ "other" ]
      [ true, false, nil ].product(calls).each do |matched, call|
        valid = described_class.new(matched: matched, human_call: call).tap(&:validate).errors[:human_call].empty?
        inserted = begin
          raw_insert(matched: matched, human_call: call)
          true
        rescue ActiveRecord::StatementInvalid
          false
        end
        expect(inserted).to eq(valid), "matched=#{matched.inspect} human_call=#{call}"
      end
    end

    matcher :be_valid_on do |attribute|
      match { |record| record.tap(&:validate).errors[attribute].empty? }
    end
  end

  describe "section_digest" do
    it "is filled from judged_section on write" do
      record = create_solve
      expect(record.section_digest).to eq(SectionDigest.call(section))
      expect(record.reload.section_digest).to match(/\A\h{64}\z/)
    end

    it "is the same for the same section in any key order, at any depth" do
      reordered = section.to_a.reverse.to_h.merge("answer_key" => section["answer_key"].to_a.reverse.to_h)

      expect(SectionDigest.call(reordered)).to eq(SectionDigest.call(section))
      expect(SectionDigest.call(section.deep_symbolize_keys)).to eq(SectionDigest.call(section))
    end

    it "changes when any field changes, nested ones included" do
      base = SectionDigest.call(section)

      expect(SectionDigest.call(section.merge("title" => "Two queues"))).not_to eq(base)
      expect(SectionDigest.call(section.merge("answer_key" => section["answer_key"].merge("better" => "b")))).not_to eq(base)
      expect(SectionDigest.call(section.merge("extra" => nil))).not_to eq(base)
    end

    it "keeps array order significant" do
      expect(SectionDigest.call("lines" => %w[a b])).not_to eq(SectionDigest.call("lines" => %w[b a]))
    end

    it "is recomputed when judged_section changes" do
      record = create_solve
      record.update!(judged_section: section.merge("title" => "Changed"))
      expect(record.section_digest).to eq(SectionDigest.call(section.merge("title" => "Changed")))
    end

    it "agrees for two records of the same section version" do
      expect(create_solve.section_digest).to eq(create_solve(judged_section: section.to_a.reverse.to_h).section_digest)
    end
  end

  describe ".record!" do
    it "inserts one live row per solve, stamped with the exercise's owner and set time" do
      solves = [ solve(shipped: false), solve(attempt: 0, edit_check: true, judge_pick: "b", matched: false) ]

      records = described_class.record!(exercise, solves, draft_model: "draft-model", app_revision: "abc123")

      expect(records.size).to eq(2)
      expect(records).to all(have_attributes(user_id: user.id, daily_exercise_id: exercise.id, source: "live",
                                             draft_model: "draft-model", app_revision: "abc123",
                                             section_digest: SectionDigest.call(section)))
      expect(records.map(&:set_generated_at)).to all(be_within(1.second).of(exercise.generated_at))
      expect(records.last).to have_attributes(edit_check: true, judge_pick: "b", matched: false, shipped: true)
      expect(exercise.judge_solves.count).to eq(2)
    end

    it "copies every solve field onto its row" do
      record = described_class.record!(exercise, [ solve(matched: nil, judge_status: nil, judge_pick: nil,
                                                         unsolved_reason: "invalid_output", unsolved_detail: "no solve") ]).first

      expect(record).to have_attributes(matched: nil, judge_status: nil, judge_pick: nil,
                                        unsolved_reason: "invalid_output", unsolved_detail: "no solve",
                                        rung: "senior", locked: false, concept: "caching", key_better: "a",
                                        judge_provider: "anthropic", judge_model: "claude-test")
      expect(record.reload.judged_section).to eq(section)
    end

    it "reads the build's revision from the environment when none is given" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("RAILWAY_GIT_COMMIT_SHA").and_return("deadbeef")

      expect(described_class.record!(exercise, [ solve ]).first.app_revision).to eq("deadbeef")
    end

    it "stores no revision when the environment has none" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("RAILWAY_GIT_COMMIT_SHA").and_return("")

      expect(described_class.record!(exercise, [ solve ]).first.app_revision).to be_nil
    end

    it "writes nothing when any row is refused" do
      solves = [ solve, solve(edit_reverted: true, revert_reason: nil) ]

      expect { described_class.record!(exercise, solves) }.to raise_error(described_class::RecordError)
      expect(described_class.count).to eq(0)
    end

    def refusal_from(solves)
      described_class.record!(exercise, solves)
    rescue described_class::RecordError => error
      error
    end

    def expect_no_row_contents(error)
      expect(error.cause).to be_nil
      expect(error.message).not_to include("Failing row", "fewer writes", "Two caches", "a = 1", "b = 2", "caching")
    end

    it "names only the constraint when the database refuses a row" do
      error = refusal_from([ solve(edit_reverted: true, revert_reason: nil) ])

      expect(error.message).to eq("judge_solves row refused: judge_solves_revert_reason_iff_reverted")
      expect_no_row_contents(error)
    end

    it "names only the column when a not-null column is missing" do
      error = refusal_from([ solve(key_better: nil) ])

      expect(error.message).to eq("judge_solves row refused: key_better")
      expect_no_row_contents(error)
    end

    it "names only the attribute when validation refuses a row" do
      error = refusal_from([ solve(edit_reverted: true, revert_reason: "made_up") ])

      expect(error.message).to eq("judge_solves row refused: revert_reason")
      expect_no_row_contents(error)
    end

    it "writes nothing for no solves" do
      expect(described_class.record!(exercise, [])).to eq([])
    end

    it "is reached from its exercise by name" do
      expect(DailyExercise.reflect_on_association(:judge_solves).klass).to eq(described_class)
    end

    it "is destroyed with its exercise" do
      described_class.record!(exercise, [ solve ])
      expect { exercise.destroy }.to change(described_class, :count).by(-1)
    end
  end

  describe ".readable" do
    def review!(target_exercise, ai_review: { "design_comparison" => { "rating" => "solid" } }, submitted: true)
      DailyResponse.create!(user: user, daily_exercise: target_exercise, date: target_exercise.date,
                            submitted_at: (Time.current if submitted), ai_review: ai_review)
    end

    it "shows a synthetic row" do
      record = create_solve(source: "synthetic", user_id: nil, daily_exercise_id: nil, set_generated_at: nil)
      expect(described_class.readable).to contain_exactly(record)
    end

    it "shows live and replay rows once their exercise's response is reviewed" do
      live = create_solve
      replay = create_solve(source: "replay")
      review!(exercise)

      expect(described_class.readable).to contain_exactly(live, replay)
    end

    it "shows a row recorded as never shown, before review" do
      retried = create_solve(shipped: false, never_shown_reason: "replaced_by_retry")
      dropped = create_solve(shipped: false, never_shown_reason: "section_dropped")

      expect(described_class.readable).to contain_exactly(retried, dropped)
    end

    it "hides an unreviewed shipped row, live or replay, with or without a submitted response" do
      create_solve
      create_solve(source: "replay")
      expect(described_class.readable).to be_empty

      review!(exercise, ai_review: nil)
      expect(described_class.readable).to be_empty
    end

    it "hides an unshipped live row that carries no reason" do
      create_solve(shipped: false)
      expect(described_class.readable).to be_empty
    end

    it "hides a reverted edit's edit-check row until review" do
      create_solve(edit_check: true, shipped: false, edit_reverted: true, revert_reason: "solve_mismatch",
                   judge_pick: "b", matched: false)
      expect(described_class.readable).to be_empty
    end

    it "hides the pre-edit draft of a kept edit until review" do
      create_solve(edit_check: false, shipped: false)
      create_solve(edit_check: true, shipped: true)
      expect(described_class.readable).to be_empty

      review!(exercise)
      expect(described_class.readable.count).to eq(2)
    end

    it "keeps one day's review from showing another day's rows" do
      other = create_solve(daily_exercise_id: exercise_on(Date.yesterday).id)
      create_solve
      review!(exercise)

      expect(described_class.readable).not_to include(other)
    end

    it "hides a row whose own section is not reviewed, even when another section of the day is" do
      create_solve
      review!(exercise, ai_review: { "code_review" => { "rating" => "solid" } })

      expect(described_class.readable).to be_empty
    end

    it "agrees with DailyResponse#section_reviewed? for every response state" do
      states = {
        reviewed: { ai_review: { "design_comparison" => { "rating" => "solid" } }, submitted: true },
        other_section_reviewed: { ai_review: { "code_review" => { "rating" => "solid" } }, submitted: true },
        section_not_a_hash: { ai_review: { "design_comparison" => "pending" }, submitted: true },
        submitted_unreviewed: { ai_review: nil, submitted: true },
        unsubmitted: { ai_review: nil, submitted: false },
        empty_review: { ai_review: {}, submitted: true },
        no_response: nil
      }

      states.each_with_index do |(name, attrs), offset|
        day = exercise_on(Date.current - (offset + 2).days)
        response = attrs && review!(day, **attrs)
        record = create_solve(daily_exercise_id: day.id)

        expected = response&.section_reviewed?(record.section) || false
        expect(described_class.readable.include?(record)).to eq(expected), name.to_s
      end
    end
  end
end
