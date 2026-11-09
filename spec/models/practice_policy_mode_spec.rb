require "rails_helper"

RSpec.describe PracticePolicyMode do
  include AuthHelpers

  let(:user) { create_user_with_key }

  def response_with(receipt, date: Date.current)
    exercise = user.daily_exercises.create!(date: date, generated_at: Time.current,
      problem_set: { "pattern" => { "question" => "Explain the pattern." } })
    user.daily_responses.create!(daily_exercise: exercise, date: exercise.date, mastery_application: receipt)
  end

  it "does not enroll an untouched user with initiation off" do
    user.with_lock { expect(described_class.active?(user, initiate: false)).to be(false) }
  end

  it "selects protected practice for an untouched user under the source-controlled default" do
    user.with_lock { expect(described_class.active?(user)).to be(true) }
    expect(user.daily_responses).to be_empty
    expect(user.daily_exercises).to be_empty
    expect(user.concept_masteries).to be_empty
  end

  it "honors a compacted v2 receipt without an open journal" do
    response = response_with({
      "version" => 2, "policy" => 2, "legacy_sections" => [], "processed_sections" => [],
      "session_counted" => false, "skip_attempts" => []
    })
    user.with_lock { expect(described_class.active?(user)).to be(true) }
    expect(response.reload.mastery_application["policy"]).to eq(2)
  end

  it "keeps receipt validation uncached and restores the caller's cache scope" do
    response_with({ "version" => 1, "legacy_sections" => [], "processed_sections" => [],
      "session_counted" => false, "skip_attempts" => [] })
    pool = ActiveRecord::Base.connection_pool
    cache_states = []
    allow(DailyResponse).to receive(:decode_mastery_application).and_wrap_original do |original, *args|
      cache_states << pool.query_cache_enabled
      original.call(*args)
    end

    user.with_lock do
      ActiveRecord::Base.cache do
        expect(pool.query_cache_enabled).to be(true)
        expect(described_class.active?(user, initiate: false)).to be(false)
        expect(pool.query_cache_enabled).to be(true)
      end
    end
    expect(cache_states).to eq([ false ])
  end

  %i[receipt journal note].each do |signal|
    it "validates the later #{signal} after a lower-ID v2 receipt with initiation off" do
      first = response_with({ "version" => 2, "policy" => 2, "legacy_sections" => [], "processed_sections" => [],
        "session_counted" => false, "skip_attempts" => [] }, date: Date.yesterday)
      case signal
      when :receipt
        expect(response_with({ "version" => 9 }).id).to be > first.id
      when :journal
        user.concept_masteries.create!(concept: "memoization", language: "ruby_rails", review_reconciliation: { "version" => 9 })
      when :note
        user.daily_exercises.create!(date: Date.current, generated_at: Time.current,
          problem_set: { "pattern" => { "question" => "Explain the pattern." } },
          plan_notes: { "practice_schedule" => { "version" => 9 } })
      end
      user.with_lock { expect { described_class.active?(user, initiate: false) }.to raise_error(ArgumentError) }
    end
  end

  it "honors materialized requests after every suffix has compacted" do
    user.concept_masteries.create!(concept: "memoization", language: "ruby_rails",
      practice_requests: { "pattern" => { "mode" => "normal_retry", "source_response_id" => 1,
        "requested_at" => "2026-11-06T12:00:00.123456Z" } })
    user.with_lock { expect(described_class.active?(user)).to be(true) }
  end

  it "honors a v2 envelope containing only v1 operations" do
    journal = JSON.parse(File.read(Rails.root.join("spec/fixtures/practice/v1-journal.json")))
    journal["version"] = 2
    journal["baseline"]["practice_requests"] = {}
    journal["operations"].each { |entry| entry["policy"] = 1 }
    user.concept_masteries.create!(concept: "memoization", language: "ruby_rails", review_reconciliation: journal)
    expect(described_class.active?(user)).to be(true)
  end

  %i[assignment service].each do |field|
    it "refuses an incompatible kind/bucket #{field} as the only persisted signal with initiation off" do
      selected = PracticeSchedule.plan(context: nil, count: DailyKinds::COUNT, setting: DailyKinds::COUNT, daily: DailyKinds::DEFAULT,
        preferences: KindPreferences.none, evidence: { initial_reviewed_sets: 0, pending: [], struggle: {} },
        hosts: DayHosts.new("ruby_rails", mode: :application_code), rotation_history: [], due: [], drills: [])
      note = selected.notes
      identity = { "concept" => "sync_vs_async", "bucket" => "architecture" }
      if field == :assignment
        note["assignments"] = { "code_review" => identity.merge("reason" => "support", "adjustment" => "support") }
      else
        note["continuation"]["service"] = { "code_review" => {
          "last_lane" => "practice", "last_maintenance" => nil,
          "concepts" => [ identity.merge("sequence" => note.fetch("sequence")) ]
        } }
      end
      exercise = user.daily_exercises.create!(date: Date.current, generated_at: Time.current,
        problem_set: selected.kinds.to_h { |kind| [ kind.key, { "question" => "Explain the decision." } ] },
        plan_notes: { "practice_schedule" => note })

      expect(user.daily_responses).to be_empty
      expect(user.concept_masteries).to be_empty
      user.with_lock do
        expect { described_class.active?(user, initiate: false) }.to raise_error(ArgumentError, "Invalid practice schedule format")
      end
      expect(exercise.reload.plan_notes).to eq("practice_schedule" => note)
    end
  end

  it "honors schedule-only enrollment and rejects a later malformed note" do
    selected = PracticeSchedule.plan(context: nil, count: DailyKinds::COUNT, setting: nil, daily: DailyKinds::DEFAULT,
      preferences: KindPreferences.none, evidence: { initial_reviewed_sets: 0, pending: [], struggle: {} },
      hosts: DayHosts.new("ruby_rails", mode: :application_code), rotation_history: [], due: [], drills: [])
    exercise = user.daily_exercises.create!(date: Date.current, generated_at: Time.current,
      problem_set: selected.kinds.to_h { |kind| [ kind.key, { "question" => "Explain the decision." } ] },
      plan_notes: { "practice_schedule" => selected.notes })
    expect(described_class.active?(user)).to be(true)
    exercise.update_columns(plan_notes: { "practice_schedule" => selected.notes.merge("version" => 1.0) })
    expect(exercise.reload.plan_notes.dig("practice_schedule", "version")).to eql(1.0)
    expect { described_class.active?(user, initiate: true) }.to raise_error(ArgumentError)
  end
end
