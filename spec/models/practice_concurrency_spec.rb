require "rails_helper"

RSpec.describe "Protected practice on PostgreSQL", type: :model do
  include LiveSolveHelpers
  self.use_transactional_tests = false

  let!(:user) { User.create!(email: "practice-concurrency-#{SecureRandom.hex(8)}@example.com") }
  after { user.destroy! }

  def connected(&work)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection.execute("SET lock_timeout = '5s'")
        work.call
      ensure
        connection.execute("RESET lock_timeout")
      end
    end
  end

  def await(queue) = Timeout.timeout(10) { queue.pop }

  def judged(context)
    selected = PracticeSchedule.plan(context: context[:note], count: DailyKinds::COUNT, setting: nil,
      daily: DailyKinds::DEFAULT, preferences: KindPreferences.none, evidence: context[:evidence],
      hosts: DayHosts.new("ruby_rails", mode: :application_code), rotation_history: [], due: [], drills: [])
    AiService::JudgedSet.new(problem_set: selected.kinds.to_h { |kind| [ kind.key, { "question" => "q" } ] },
      dropped_sections: [], outcomes: {}, schedule_context: context,
      plan_notes: { "daily_kinds" => DailyKinds::DEFAULT.map(&:key), "practice_schedule" => selected.notes })
  end

  it "discards a v2 review after another connection takes the claim, preserving the new token and request" do
    exercise = user.daily_exercises.create!(date: Date.current, generated_at: Time.current,
      problem_set: { "pattern" => { "concept" => "memoization" } })
    response = user.daily_responses.create!(date: exercise.date, daily_exercise: exercise, submitted_at: Time.current,
      answers: { "pattern" => "An answer" }, concept_tags: { "pattern" => "memoization" }, section_ratings: { "pattern" => "right_level" })
    request = { "pattern" => { "mode" => "normal_retry", "source_response_id" => response.id, "requested_at" => Time.current.utc.iso8601(6) } }
    row = user.concept_masteries.create!(concept: "memoization", language: "ruby_rails", practice_requests: request)
    original = row.attributes
    ready, release = Queue.new, Queue.new
    worker = connected do
      reviewer = Object.new
      reviewer.define_singleton_method(:review_sections) do |*_args, sections:|
        ready << true
        Timeout.timeout(10) { release.pop }
        sections.index_with { { ok: true, review: { "rating" => "solid" } } }
      end
      ResponseReview.new(DailyResponse.find(response.id), user: User.find(user.id), reviewer: reviewer).call
    end
    await(ready)
    response.update_columns(reviewing_since: (DailyResponse::REVIEW_CLAIM_STALE_AFTER + 1.minute).ago)
    takeover = response.reload.claim_reviewing!
    release << true
    expect(worker.value.status).to eq(:busy)
    expect(response.reload).to have_attributes(ai_review: nil, mastery_application: {}, review_errors: {}, reviewing_since: takeover)
    expect(row.reload.attributes).to eq(original)
  ensure
    release << true if release
    worker&.join
  end

  %i[settings held_date takeover].each do |change|
    context "after #{change} changes" do
      around { |example| change == :held_date ? travel_to(Time.utc(2026, 11, 10, 3)) { example.run } : example.run }

      it "rejects an active replacement after #{change} changes while the draft is away" do
        service = FakeService.new("fake-key")
        initial = PracticeGeneration.capture(user, date: Time.use_zone(user.effective_time_zone) { Date.yesterday })
        exercise = PracticeGeneration.commit_new(user, context: initial, judged: judged(initial),
          language: "ruby_rails", drafted_by: service).exercise
        response = user.daily_responses.create!(date: exercise.date, daily_exercise: exercise, answers: { "code_review" => "Old draft" })
        JudgeSolve.record!(exercise, [ live_solve ])
        old_solves = JudgeSolve.where(daily_exercise_id: exercise.id).map(&:attributes)
        claim = exercise.claim_regenerating!
        ready, release = Queue.new, Queue.new
        worker = connected do
          caller = User.find(user.id)
          held = DailyExercise.find(exercise.id)
          context = PracticeGeneration.capture(caller, date: held.date, replacing: held)
          draft = judged(context).with(solves: [ live_solve(judge_pick: "a", matched: false) ])
          ready << true
          await(release)
          result = PracticeGeneration.commit_replacement(caller, exercise: held, claim: claim, context: context,
            judged: draft, drafted_by: service)
          held.release_regenerating!(claim)
          result
        end
        await(ready)
        case change
        when :settings then user.update!(daily_section_count: 2)
        when :held_date
          user.update!(paused_generation_at: 2.days.ago)
          expect(user.carry_held_set_forward!&.id).to eq(exercise.id)
        when :takeover
          exercise.update_columns(regenerating_since: (DailyExercise::REGENERATION_STALE_AFTER + 1.minute).ago)
          expect(exercise.reload.claim_regenerating!).to be_present
        end
        expected_set = exercise.reload.attributes.except("regenerating_since", "updated_at")
        expected_token = change == :takeover ? exercise.regenerating_since : nil
        expected_response = response.reload.attributes
        release << true
        expect(worker.value.status).to eq(:superseded)
        expect(exercise.reload.attributes.except("regenerating_since", "updated_at")).to eq(expected_set)
        expect(exercise.regenerating_since).to eq(expected_token)
        expect(response.reload.attributes).to eq(expected_response)
        expect(JudgeSolve.where(daily_exercise_id: exercise.id).map(&:attributes)).to eq(old_solves)
      ensure
        release << true if release
        worker&.join
      end
    end
  end

  it "refuses an active new set when another connection changes settings during the fake draft" do
    ready, release = Queue.new, Queue.new
    worker = connected do
      caller = User.find(user.id)
      context = PracticeGeneration.capture(caller, date: Date.current)
      result = judged(context)
      ready << true
      await(release)
      PracticeGeneration.commit_new(caller, context: context, judged: result, language: "ruby_rails", drafted_by: FakeService.new("fake-key"))
    end
    await(ready)
    user.update!(daily_section_count: 2)
    release << true
    expect(worker.value.status).to eq(:superseded)
    expect(user.daily_exercises).to be_empty
    expect(JudgeSolve.where(user_id: user.id)).to be_empty
  ensure
    release << true if release
    worker&.join
  end

  [ 0, 1 ].each do |offset|
    it "commits one successor when concurrent captures target dates #{offset} day apart" do
      ready, release = Queue.new, Queue.new
      threads = [ 0, offset ].map do |day|
        connected do
          caller = User.find(user.id)
          context = PracticeGeneration.capture(caller, date: Date.current + day)
          draft = judged(context)
          ready << true
          await(release)
          PracticeGeneration.commit_new(caller, context: context, judged: draft, language: "ruby_rails", drafted_by: FakeService.new("fake-key"))
        end
      end
      threads.size.times { await(ready) }
      threads.size.times { release << true }
      expect(threads.map { |thread| thread.value.status }).to match_array([ :saved, offset.zero? ? :duplicate : :superseded ])
      expect(user.daily_exercises.count).to eq(1)
      expect(user.daily_exercises.sole.practice_schedule["sequence"]).to eq(1)
    ensure
      threads&.size&.times { release << true }
      threads&.each(&:join)
    end
  end

  %i[receipt schedule].each do |signal|
    it "chooses v2 only after the lock with an actual cached negative #{signal} query" do
    stub_const("PracticePolicyMode::INITIATE_PRACTICE_POLICY", false)
    exercise = user.daily_exercises.create!(date: Date.current, generated_at: Time.current,
      problem_set: { "pattern" => { "concept" => "memoization", "eased" => true } })
    response = user.daily_responses.create!(date: exercise.date, daily_exercise: exercise, submitted_at: Time.current,
      answers: { "pattern" => "A substantive answer" }, concept_tags: { "pattern" => "memoization" }, section_ratings: { "pattern" => "right_level" })
    legacy_set = user.daily_exercises.create!(date: Date.yesterday, generated_at: Time.current,
      problem_set: { "pattern" => { "question" => "Explain the pattern." } })
    legacy = user.daily_responses.create!(date: legacy_set.date, daily_exercise: legacy_set, mastery_application: {
      "version" => 1, "legacy_sections" => [], "processed_sections" => [], "session_counted" => false, "skip_attempts" => []
    })
    ready, release, locking = Queue.new, Queue.new, Queue.new
    worker = connected do
      ApplicationRecord.cache do
        caller = User.find(user.id)
        relation = signal == :receipt ? caller.daily_responses.where("mastery_application @> ?", { policy: 2 }.to_json) :
          caller.daily_exercises.where("plan_notes ? 'practice_schedule'")
        cache_negative = lambda do
          cached = []
          subscriber = ->(*, payload) { cached << payload if payload[:cached] }
          ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
            2.times { expect(relation.exists?).to be(false) }
          end
          expect(cached).not_to be_empty
        end
        reviewer = Object.new
        reviewer.define_singleton_method(:review_sections) do |*_args, sections:|
          cache_negative.call
          ready << true
          Timeout.timeout(10) { release.pop }
          sections.index_with { { ok: true, review: { "rating" => "solid" } } }
        end
        ResponseReview.new(DailyResponse.find(response.id), user: caller, reviewer: reviewer).call
      end
    end
    await(ready)
    allow(User).to receive(:lock).and_wrap_original do |method, *args|
      locking << true if Thread.current == worker
      method.call(*args)
    end
    user.with_lock do
      if signal == :receipt
        source = user.daily_exercises.create!(date: Date.tomorrow, generated_at: Time.current,
          problem_set: { "pattern" => { "question" => "Explain the pattern." } })
        user.daily_responses.create!(date: source.date, daily_exercise: source, mastery_application: {
          "version" => 2, "policy" => 2, "legacy_sections" => [], "processed_sections" => [],
          "session_counted" => false, "skip_attempts" => []
        })
      else
        context = PracticeGeneration.capture(user, date: Date.current)
        note = judged(context.merge(evidence: { initial_reviewed_sets: 0, pending: [], struggle: {} })).plan_notes
        exercise.update!(plan_notes: note)
      end
      release << true
      await(locking)
    end
    expect(worker.value.status).to eq(:ready)
    expect(response.reload.mastery_application).to include("version" => 2, "policy" => 2)
    expect(user.concept_masteries.find_by!(concept: "memoization")).to have_attributes(
      mastered_at: nil, retention_interval_days: nil, next_retention_check_on: nil,
      practice_requests: include("pattern" => include("mode" => "normal_retry")))
    expect(legacy.reload.mastery_application["version"]).to eq(1)
  ensure
    release << true if release
    worker&.join
    end
  end
end
