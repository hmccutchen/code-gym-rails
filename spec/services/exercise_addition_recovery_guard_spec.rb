require "rails_helper"

RSpec.describe "Recovery leaves a live addition's worker free to start" do
  include AuthHelpers
  self.use_transactional_tests = false

  let!(:user) { create_fake_provider_user }
  let!(:exercise) do
    user.daily_exercises.create!(date: Date.current, generated_at: Time.current, language: "ruby_rails",
      section_order: %w[code_review], problem_set: { "code_review" => { "question" => "Review this" } })
  end

  after { user.destroy! if User.exists?(user.id) }

  def wait_for(queue) = Timeout.timeout(10) { queue.pop }

  it "does not make a newly queued worker exit while a submit checks for abandoned work" do
    addition = exercise.exercise_additions.create!(request_uuid: SecureRandom.uuid, kind: "pattern",
      draft_scope: exercise.draft_scope, date: exercise.date)
    entered, release = Queue.new, Queue.new
    allow(ExerciseAdditionRequest).to receive(:recover_locked!).and_wrap_original do |method, *arguments|
      entered << :locked
      wait_for(release)
      method.call(*arguments)
    end
    recovery = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ExerciseAdditionRequest.recover!(DailyExercise.find(exercise.id))
        entered << :finished
      end
    end
    state = wait_for(entered)

    GenerateAdditionalExerciseJob.perform_now(addition_id: addition.id)

    release << true if state == :locked
    recovery.join
    expect(addition.reload.status).to eq("succeeded")
  ensure
    release << true if release
    recovery&.join
  end
end
