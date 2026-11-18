require "rails_helper"

RSpec.describe "An autosave racing Start over on PostgreSQL", type: :request do
  self.use_transactional_tests = false

  let!(:user) { create_user_with_key(email: "reset-race-#{SecureRandom.hex(8)}@example.com") }
  let!(:exercise) do
    user.daily_exercises.create!(date: Date.current, generated_at: Time.current,
      problem_set: { "code_review" => { "question" => "q", "snippet" => "s" } })
  end
  let!(:draft) do
    user.daily_responses.create!(daily_exercise: exercise, date: exercise.date, answers: { "code_review" => "Before reset." })
  end

  before { login_as(user) }
  after { AccountDeletion.call(user) }

  def another_tab
    ActionDispatch::Integration::Session.new(Rails.application).tap do |tab|
      key = Rails.application.config.session_options[:key]
      tab.cookies[key] = cookies[key]
    end
  end

  def in_another_connection(&work)
    CallerZoneThread.start do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection.execute("SET lock_timeout = '10s'")
        work.call(connection)
      ensure
        connection.execute("RESET lock_timeout")
      end
    end
  end

  def wait_for_blocked_request(thread, pid)
    Timeout.timeout(10) do
      loop do
        blocked = ActiveRecord::Base.uncached do
          ActiveRecord::Base.connection.select_value("SELECT cardinality(pg_blocking_pids(#{Integer(pid)}))")
        end
        break if blocked.positive?
        raise "request finished without waiting for reset" unless thread.alive?

        Thread.pass
      end
    end
  end

  it "holds the exercise until reset commits, then refuses the queued old-scope save" do
    scope = exercise.draft_scope
    tab, ready, saving = another_tab, Queue.new, nil
    [ :destroy, :destroy! ].each do |operation|
      allow_any_instance_of(DailyResponse).to receive(operation).and_wrap_original do |original, *args|
        unless saving
          ActiveSupport::Dependencies.interlock.permit_concurrent_loads do
            saving = in_another_connection do |connection|
              ready << connection.select_value("SELECT pg_backend_pid()")
              tab.post responses_path, params: { response: { draft_scope: scope, answers: { code_review: "Late answer." } } }, as: :json
            end
            wait_for_blocked_request(saving, Timeout.timeout(10) { ready.pop })
          end
        end
        original.call(*args)
      end
    end

    delete start_over_response_path(draft)
    saving.value

    expect(response).to redirect_to(root_path)
    expect(tab.response).to have_http_status(:conflict)
    expect(user.daily_responses.reload).to be_empty
    expect(exercise.reload.draft_scope).not_to eq(scope)
  ensure
    saving&.join
  end

  it "lets an already locked save finish before reset clears its answer" do
    scope = exercise.draft_scope
    tab, ready, resetting = another_tab, Queue.new, nil
    allow_any_instance_of(ResponsesController).to receive(:stale_draft_scope?).and_wrap_original do |original, *args|
      ActiveSupport::Dependencies.interlock.permit_concurrent_loads do
        resetting = in_another_connection do |connection|
          ready << connection.select_value("SELECT pg_backend_pid()")
          tab.delete start_over_response_path(draft)
        end
        wait_for_blocked_request(resetting, Timeout.timeout(10) { ready.pop })
      end
      original.call(*args)
    end

    post responses_path, params: { response: { draft_scope: scope, answers: { code_review: "In flight." } } }, as: :json
    resetting.value

    expect(response).to have_http_status(:ok)
    expect(tab.response).to have_http_status(:redirect)
    expect(user.daily_responses.reload).to be_empty
    expect(exercise.reload.draft_scope).not_to eq(scope)
  ensure
    resetting&.join
  end
end
