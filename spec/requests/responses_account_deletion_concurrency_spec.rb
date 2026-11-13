require "rails_helper"

RSpec.describe "An autosave racing account deletion on PostgreSQL", type: :request do
  self.use_transactional_tests = false

  WAITING_LOCKS = "SELECT count(*) FROM pg_locks WHERE NOT granted".freeze

  let!(:user) { create_user_with_key(email: "autosave-race-#{SecureRandom.hex(8)}@example.com") }
  let!(:exercise) do
    DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
                          problem_set: { "code_review" => { "concept" => "n_plus_one", "question" => "q", "snippet" => "s" } })
  end

  after { AccountDeletion.call(user) }

  def deletion_in_another_connection
    Thread.new do
      Thread.current.report_on_exception = false
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection.execute("SET lock_timeout = '10s'")
        AccountDeletion.call(user)
      ensure
        connection.execute("RESET lock_timeout")
      end
    end
  end

  def wait_until_blocked(thread)
    Timeout.timeout(10) do
      loop do
        break if ActiveRecord::Base.uncached { ActiveRecord::Base.connection.select_value(WAITING_LOCKS) }.positive?
        raise "deletion finished without waiting" unless thread.alive?

        Thread.pass
      end
    end
  end

  it "lets the first save of the day finish before the deletion removes it" do
    login_as(user)
    deletion = nil
    allow_any_instance_of(ResponsesController).to receive(:stale_draft_scope?).and_wrap_original do |original, *args|
      deletion ||= ActiveSupport::Dependencies.interlock.permit_concurrent_loads do
        deletion_in_another_connection.tap { |thread| wait_until_blocked(thread) }
      end
      original.call(*args)
    end

    post responses_path, params: { response: { answers: { code_review: "Preload the records." } } }, as: :json

    expect(response).to have_http_status(:ok)
    expect(deletion.value.status).to eq(:deleted)
    expect([ User.exists?(user.id), DailyResponse.where(user_id: user.id).exists?, DailyExercise.exists?(exercise.id) ])
      .to eq([ false, false, false ])
  ensure
    deletion&.join
  end
end
