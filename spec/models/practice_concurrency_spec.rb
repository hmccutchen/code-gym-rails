require "rails_helper"

RSpec.describe "Protected practice on PostgreSQL", type: :model do
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

  [ 0, 1 ].each do |offset|
    it "commits one successor when concurrent captures target dates #{offset} day apart" do
      stub_const("PracticePolicyMode::INITIATE_PRACTICE_POLICY", true)
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

  it "chooses v2 after acquiring the user lock even with a pre-enrollment query cache" do
    exercise = user.daily_exercises.create!(date: Date.current, generated_at: Time.current,
      problem_set: { "pattern" => { "concept" => "memoization", "eased" => true } })
    response = user.daily_responses.create!(date: exercise.date, daily_exercise: exercise, submitted_at: Time.current,
      answers: { "pattern" => "A substantive answer" }, concept_tags: { "pattern" => "memoization" }, section_ratings: { "pattern" => "right_level" })
    ready, release = Queue.new, Queue.new
    worker = connected do
      ApplicationRecord.cache do
        caller = User.find(user.id)
        expect(PracticePolicyMode.active?(caller)).to be(false)
        reviewer = Object.new
        reviewer.define_singleton_method(:review_sections) do |*_args, sections:|
          ready << true
          Timeout.timeout(10) { release.pop }
          sections.index_with { { ok: true, review: { "rating" => "solid" } } }
        end
        ResponseReview.new(DailyResponse.find(response.id), user: caller, reviewer: reviewer).call
      end
    end
    await(ready)
    user.with_lock do
      user.concept_masteries.create!(concept: "n_plus_one", language: "ruby_rails", practice_requests: {
        "pattern" => { "mode" => "support", "source_response_id" => response.id, "requested_at" => Time.current.utc.iso8601(6) }
      })
    end
    release << true
    expect(worker.value.status).to eq(:ready)
    expect(response.reload.mastery_application).to include("version" => 2, "policy" => 2)
    expect(user.concept_masteries.find_by!(concept: "memoization").mastered_at).to be_nil
  ensure
    release << true if release
    worker&.join
  end
end
