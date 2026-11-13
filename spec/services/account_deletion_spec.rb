require "rails_helper"

RSpec.describe AccountDeletion, type: :model do
  include ActiveJob::TestHelper

  def section(tag) = { "title" => tag, "piece_a" => "a", "piece_b" => "b", "answer_key" => { "better" => "a" } }

  def give_rows(user, tag)
    exercise = DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current.change(usec: 0), language: "ruby_rails",
                                     problem_set: { "design_comparison" => section(tag) })
    response = DailyResponse.create!(user: user, daily_exercise: exercise, date: exercise.date, submitted_at: Time.current,
                                     ai_review: { "design_comparison" => { "rating" => "solid" } })
    response.review_follow_ups.create!(section: "design_comparison", role: :user, content: "Why #{tag}?")
    DuckThread.create!(user: user, daily_exercise: exercise, draft_scope: exercise.draft_scope, threads: {})
    JudgeSolve.create!(user_id: user.id, daily_exercise: exercise, set_generated_at: exercise.generated_at, source: "live",
                       section: "design_comparison", attempt: 0, edit_check: false, shipped: true, edit_reverted: false,
                       rung: "senior", locked: false, key_better: "a", judge_pick: "a", matched: true,
                       judged_section: section(tag), judge_provider: "anthropic", judge_model: "claude-test")
    user.push_subscriptions.create!(endpoint: "https://fcm.googleapis.com/#{tag}", p256dh_key: "p", auth_key: "a")
    user.api_usages.create!(purpose: "review_response", date: Date.current, provider: "anthropic", tokens_in: 1, tokens_out: 1)
    user.concept_masteries.create!(concept: "open_closed", language: "ruby_rails")
    user.featured_concepts.create!(week_of: Date.current.beginning_of_week, bucket: "ruby_rails", concept: "open_closed")
    user.level_suggestion_events.create!(kind: "code_review", action: "dismissed")
    user.daily_kind_swap_events.create!(place: 0, from_kind: "code_review", to_kind: "pattern", today_section: "no_set")
    SuggestedConcept.create!(language: "ruby_rails", normalized_name: "#{tag} idea", display_name: "#{tag} idea",
                             first_seen_at: Time.current, last_seen_at: Time.current, status: "dismissed",
                             reviewed_by: user, reviewed_at: Time.current)
    exercise
  end

  def stored_job(job)
    SolidQueue::Job.create!(queue_name: job.queue_name, class_name: job.class.name, arguments: job.serialize,
                            active_job_id: job.job_id, priority: 0)
  end

  def running(solid_job)
    process = SolidQueue::Process.create!(kind: "Worker", last_heartbeat_at: Time.current, pid: 1, hostname: "spec", name: "worker-spec")
    solid_job.ready_execution&.destroy!
    SolidQueue::ClaimedExecution.create!(job: solid_job, process_id: process.id)
    solid_job
  end

  def rows_in_every_table(held)
    held.transform_values(&:size)
  end

  let(:leaving) { create_trial_user(email: "leaving@example.com") }
  let(:staying) { create_user_with_key(email: "staying@example.com") }

  it "deletes the account and every row naming it, and leaves another account's rows alone" do
    exercise = give_rows(leaving, "leaving")
    give_rows(staying, "staying")
    references = user_references
    held_before = user_ids_held(leaving, references)
    staying_before = rows_in_every_table(user_ids_held(staying, references))

    outcome = described_class.call(leaving)

    expect(outcome.status).to eq(:deleted)
    remaining = references.select do |ref|
      ref.target == :email ? rows_naming(ref, [ leaving.email ]).exists? : rows_naming(ref, held_before.fetch(ref.target, [])).exists?
    end
    expect(remaining.map { |ref| [ ref.table, ref.column ] }).to eq([])
    expect(held_before.keys).to include("daily_responses", "review_follow_ups", "judge_solves", "api_usages", "suggested_concepts")
    expect(rows_in_every_table(user_ids_held(staying, references))).to eq(staying_before)
    expect(SuggestedConcept.where(normalized_name: "leaving idea").pick(:reviewed_by_id, :status)).to eq([ nil, "dismissed" ])
    expect(DailyExercise.exists?(exercise.id)).to be(false)
  end

  it "gives the invite seat back and keeps the code" do
    invite = leaving.invite_code
    expect(invite.redeemed_count).to eq(1)

    described_class.call(leaving)

    expect(invite.reload.redeemed_count).to eq(0)
  end

  it "keeps the shared text that names no one" do
    ConceptReference.create!(concept: "open_closed", language: "ruby_rails", tagline: "t", explanation: "e", code_example: "c",
                             senior_lens: "s", generation_version: 1)

    described_class.call(leaving)

    expect(ConceptReference.count).to eq(1)
  end

  it "deletes the account's unfinished jobs and leaves a running one and another account's jobs" do
    give_rows(leaving, "leaving")
    response = leaving.daily_responses.first
    queued = stored_job(GenerateDailyExercisesJob.new(user_id: leaving.id))
    mailed = stored_job(ActionMailer::MailDeliveryJob.new("ReviewMailer", "send_review", "deliver_now", args: [ response ]))
    login_mail = stored_job(ActionMailer::MailDeliveryJob.new("UserMailer", "login_code", "deliver_now", args: [ leaving ]))
    running_job = running(stored_job(RegenerateExerciseJob.new(user_id: leaving.id)))
    other = stored_job(GenerateDailyExercisesJob.new(user_id: staying.id))
    shared = stored_job(SweepDuckThreadsJob.new)

    described_class.call(leaving)

    expect(SolidQueue::Job.where(id: [ queued.id, mailed.id, login_mail.id ])).to be_empty
    expect(SolidQueue::ReadyExecution.where(job_id: [ queued.id, mailed.id, login_mail.id ])).to be_empty
    expect(SolidQueue::Job.where(id: [ running_job.id, other.id, shared.id ]).count).to eq(3)
  end

  it "takes the user row, then the exercises, then the responses, then the mastery rows" do
    give_rows(leaving, "leaving")
    locked = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      table = payload[:sql][/FROM "(\w+)".*FOR UPDATE/m, 1]
      locked << table if table && locked.last != table
    end

    described_class.call(leaving)

    ActiveSupport::Notifications.unsubscribe(subscriber)
    expect(locked.first(4)).to eq(%w[users daily_exercises daily_responses concept_masteries])
  end

  it "reports an account that is already gone" do
    described_class.call(leaving)

    expect(described_class.call(leaving).status).to eq(:already_deleted)
  end
end
