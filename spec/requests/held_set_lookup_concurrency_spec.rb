require "rails_helper"

RSpec.describe "Two requests moving one held set on PostgreSQL", type: :request do
  self.use_transactional_tests = false

  let!(:user) { create_user_with_key(email: "held-race-#{SecureRandom.hex(8)}@example.com") }
  let!(:held) do
    user.daily_exercises.create!(date: Date.current - 1, generated_at: Time.current,
                                 problem_set: { "code_review" => { "question" => "q", "snippet" => "s" } })
  end
  let!(:draft) { user.daily_responses.create!(daily_exercise: held, date: held.date, answers: { "code_review" => "Before." }) }

  before do
    stub_env("HELD_SET_LOOKUP" => "1")
    user.update!(paused_generation_at: Time.current - 1.day)
    login_as(user)
  end

  after { AccountDeletion.call(user) }

  def another_tab
    ActionDispatch::Integration::Session.new(Rails.application).tap do |tab|
      key = Rails.application.config.session_options[:key]
      tab.cookies[key] = cookies[key]
    end
  end

  def in_another_connection(start, &work)
    CallerZoneThread.start do
      ActiveRecord::Base.connection_pool.with_connection do
        start.pop
        work.call
      end
    end
  end

  it "moves the set once when a duck Clear and an autosave arrive together, and the second sees today's set" do
    scope = held.draft_scope
    saving_tab, clearing_tab, start = another_tab, another_tab, Queue.new
    threads = ActiveSupport::Dependencies.interlock.permit_concurrent_loads do
      requests = [
        in_another_connection(start) do
          saving_tab.post responses_path, params: { response: { draft_scope: scope, answers: { code_review: "After." } } }, as: :json
        end,
        in_another_connection(start) do
          clearing_tab.delete duck_thread_responses_path, params: { section: "code_review", draft_scope: scope }, as: :json
        end
      ]
      2.times { start << true }
      requests.each(&:join)
      requests
    end

    expect(threads.map(&:value)).to all(be_truthy)
    expect([ saving_tab.response.status, clearing_tab.response.status ]).to eq([ 200, 200 ])
    expect(user.daily_exercises.where(date: Date.current).pluck(:id)).to eq([ held.id ])
    expect(held.reload.draft_scope).to eq(scope)
    expect(draft.reload).to have_attributes(date: Date.current, answers: { "code_review" => "After." })
  end

  it "finds the set when another request moves it between this request's first read and its own move" do
    scope = held.draft_scope
    saving_tab, raced, saving = another_tab, false, nil
    allow_any_instance_of(User).to receive(:carry_held_set_forward!).and_wrap_original do |original, *args|
      unless raced
        raced = true
        ActiveSupport::Dependencies.interlock.permit_concurrent_loads do
          saving = in_another_connection(Queue.new.tap { |go| go << true }) do
            saving_tab.post responses_path, params: { response: { draft_scope: scope, answers: { code_review: "After." } } }, as: :json
          end
          saving.join
        end
      end
      original.call(*args)
    end

    delete duck_thread_responses_path, params: { section: "code_review", draft_scope: scope }, as: :json

    expect([ saving_tab.response.status, response.status ]).to eq([ 200, 200 ])
    expect(user.daily_exercises.where(date: Date.current).pluck(:id)).to eq([ held.id ])
  ensure
    saving&.join
  end

  it "shows the moved set on a dashboard load that loses the move to another tab, whatever the switch" do
    stub_env("HELD_SET_LOOKUP" => nil)
    scope = held.draft_scope
    saving_tab, raced, saving = another_tab, false, nil
    allow_any_instance_of(User).to receive(:carry_held_set_forward!).and_wrap_original do |original, *args|
      unless raced
        raced = true
        ActiveSupport::Dependencies.interlock.permit_concurrent_loads do
          saving = in_another_connection(Queue.new.tap { |go| go << true }) { saving_tab.get root_path }
          saving.join
        end
      end
      original.call(*args)
    end

    get root_path

    expect(saving_tab.response.body).to include(%(data-fresh-day-shown-value="#{scope}"))
    expect(response.body).to include(%(data-fresh-day-shown-value="#{scope}"))
    expect(response.body).to include("Before.")
  ensure
    saving&.join
  end

  it "keeps the user, exercise, response lock order when two threads call #current_exercise! at once" do
    start = Queue.new
    callers = ActiveSupport::Dependencies.interlock.permit_concurrent_loads do
      workers = 2.times.map { in_another_connection(start) { User.find(user.id).current_exercise!(carry: true)&.id } }
      2.times { start << true }
      workers.map(&:value)
    end

    expect(callers).to eq([ held.id, held.id ])
    expect(user.daily_exercises.where(date: Date.current).pluck(:id)).to eq([ held.id ])
    expect(draft.reload.date).to eq(Date.current)
  end
end
