require "rails_helper"

RSpec.describe ApplicationMailer, type: :mailer do
  let(:user) { User.create!(email: "leaving@example.com") }

  def run_on_solid_queue(active_job)
    solid_job = SolidQueue::Job.enqueue(active_job)
    process = SolidQueue::Process.create!(kind: "Worker", last_heartbeat_at: Time.current, pid: 1, hostname: "spec", name: "worker-spec")
    solid_job.ready_execution&.destroy!
    SolidQueue::ClaimedExecution.create!(job: solid_job, process_id: process.id).perform
    solid_job.reload
  end

  it "ends a mail job whose records were deleted with the account instead of keeping it as a failed job" do
    exercise = user.daily_exercises.create!(date: Date.current, generated_at: Time.current, language: "ruby_rails", problem_set: { "code_review" => { "question" => "q" } })
    response = user.daily_responses.create!(daily_exercise: exercise, date: exercise.date, submitted_at: Time.current)
    mail_job = ActionMailer::MailDeliveryJob.new("ReviewMailer", "send_review", "deliver_now", args: [ response ])
    AccountDeletion.call(user)

    solid_job = nil
    expect { solid_job = run_on_solid_queue(mail_job) }.not_to change(ActionMailer::Base.deliveries, :count)

    expect(SolidQueue::FailedExecution.where(job_id: solid_job.id)).to be_empty
    expect(solid_job.finished_at).to be_present
  end
end
