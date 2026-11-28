require "rails_helper"

RSpec.describe "Exercise addition coordination on PostgreSQL" do
  include AuthHelpers
  self.use_transactional_tests = false

  let!(:user) { create_fake_provider_user }
  let!(:exercise) do
    user.daily_exercises.create!(date: Date.current, generated_at: Time.current, language: "ruby_rails",
      section_order: %w[code_review], problem_set: { "code_review" => { "question" => "Review this" } })
  end

  after { user.destroy! if User.exists?(user.id) }

  def request(uuid = SecureRandom.uuid)
    ExerciseAdditionRequest.call(user: User.find(user.id), exercise: DailyExercise.find(exercise.id),
      request_uuid: uuid, kind: "pattern", draft_scope: exercise.draft_scope, revision: 1, enqueue: ->(_addition) { true })
  end

  def connection_thread(&block)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection.execute("SET lock_timeout = '5s'")
        block.call
      ensure
        connection.execute("RESET lock_timeout")
      end
    end
  end

  def wait_for(queue) = Timeout.timeout(10) { queue.pop }

  it "accepts only one of two concurrent distinct requests" do
    gate = Queue.new
    threads = 2.times.map { connection_thread { wait_for(gate); request } }
    2.times { gate << true }

    expect(threads.map(&:value).map(&:status)).to contain_exactly(:accepted, :busy)
    expect(exercise.exercise_additions.active.count).to eq(1)
  ensure
    threads&.each(&:join)
  end

  it "does not recover an expired lease while an executing worker holds the advisory lock" do
    addition = request.addition
    addition.update!(status: "running", claimed_at: DailyExercise::REGENERATION_STALE_AFTER.ago - 1.second)
    entered, release = Queue.new, Queue.new
    worker = connection_thread do
      AdvisoryLock.hold(ExerciseAdditionRequest.claim_key(exercise)) { entered << true; wait_for(release) }
    end
    wait_for(entered)

    expect(ExerciseAdditionRequest.recover!(exercise)).to eq(:busy)
    expect(request.status).to eq(:busy)
    expect(addition.reload.status).to eq("running")
    release << true
    worker.join

    expect(ExerciseAdditionRequest.recover!(exercise)).to eq(:recovered)
    expect(addition.reload.status).to eq("failed")
  ensure
    release << true if release
    worker&.join
  end

  it "keeps provider work outside row locks and suppresses duplicate workers" do
    addition = request.addition
    entered, release = Queue.new, Queue.new
    provider = instance_double(FakeService)
    calls = Queue.new
    allow(AiService).to receive(:for).and_return(provider)
    allow(provider).to receive(:generate_judged_exercise) do
      calls << true
      entered << true
      wait_for(release)
      raise ProviderError, "upstream unavailable"
    end
    worker = connection_thread { GenerateAdditionalExerciseJob.perform_now(addition_id: addition.id) }
    wait_for(entered)

    exercise.with_response_locked do |response|
      expect(response).to be_nil
      user.daily_responses.create!(daily_exercise: exercise, date: exercise.date, answers: { "code_review" => "Draft kept" })
    end
    GenerateAdditionalExerciseJob.perform_now(addition_id: addition.id)
    expect(calls.size).to eq(1)
    expect(ExerciseAdditionRequest.recover!(exercise)).to eq(:busy)
    release << true
    worker.join

    expect(addition.reload.status).to eq("failed")
    expect(exercise.reload.daily_response.answers).to eq("code_review" => "Draft kept")
  ensure
    release << true if release
    worker&.join
  end
end
