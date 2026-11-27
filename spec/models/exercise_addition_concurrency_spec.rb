require "rails_helper"

RSpec.describe "Concurrent exercise additions on PostgreSQL", type: :model do
  self.use_transactional_tests = false

  let(:user) { User.create!(email: "addition-concurrency-#{SecureRandom.hex(8)}@example.com") }
  let(:exercise) do
    user.daily_exercises.create!(date: Date.current, generated_at: Time.current,
                                 problem_set: { "code_review" => { "question" => "What would you change?" } })
  end

  after { user.destroy! }

  def insert_on_another_connection(attributes, backend_pid)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection.execute("SET lock_timeout = '5s'")
        backend_pid << connection.select_value("SELECT pg_backend_pid()")
        ExerciseAddition.create!(attributes)
        :saved
      ensure
        connection.execute("RESET lock_timeout")
      end
    rescue ActiveRecord::RecordNotUnique
      :duplicate
    end
  end

  def wait_for_blocked_insert(backend_pid)
    pid = Integer(Timeout.timeout(5) { backend_pid.pop })
    connection = ActiveRecord::Base.connection
    Timeout.timeout(3) do
      until connection.select_value("SELECT pg_backend_pid() = ANY(pg_blocking_pids(#{pid}))")
        sleep 0.01
      end
    end
  end

  it "rejects a distinct active request blocked on another connection's uncommitted insert" do
    attributes = { daily_exercise_id: exercise.id, request_uuid: SecureRandom.uuid, kind: "pattern",
                   draft_scope: exercise.draft_scope, date: exercise.date }
    backend_pid = Queue.new
    contender = nil

    ExerciseAddition.transaction do
      ExerciseAddition.create!(attributes)
      contender = insert_on_another_connection(attributes.merge(request_uuid: SecureRandom.uuid), backend_pid)
      wait_for_blocked_insert(backend_pid)
    end

    expect(Timeout.timeout(10) { contender.value }).to eq(:duplicate)
    expect(exercise.exercise_additions.sole.request_uuid).to eq(attributes[:request_uuid])
  ensure
    contender&.join(10)
  end
end
