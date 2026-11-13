require "rails_helper"

RSpec.describe "Work in flight when an account is deleted", type: :model do
  include ActiveJob::TestHelper

  let(:user) { create_fake_provider_user(email: "leaving@example.com") }
  let(:logged) { StringIO.new }

  before { allow(Rails).to receive(:logger).and_return(ActiveSupport::Logger.new(logged)) }

  def delete_account_during_the_provider_call(target = user)
    deleted = false
    allow_any_instance_of(FakeService).to receive(:call).and_wrap_original do |original, request|
      original.call(request).tap do
        AccountDeletion.call(target) unless deleted
        deleted = true
      end
    end
  end

  def todays_set(owner = user)
    DailyExercise.create!(user: owner, date: Date.current, generated_at: Time.current, language: "ruby_rails",
                          problem_set: { "code_review" => { "concept" => "n_plus_one", "question" => "q", "snippet" => "s" } })
  end

  def submitted_response(exercise)
    DailyResponse.create!(user: exercise.user, daily_exercise: exercise, date: exercise.date, submitted_at: Time.current,
                          answers: { "code_review" => "Preload the records." }, section_ratings: { "code_review" => "right_level" })
  end

  it "lets a running generation finish its call, then write nothing and stop quietly" do
    delete_account_during_the_provider_call

    expect { GenerateDailyExercisesJob.perform_now(user_id: user.id) }.not_to raise_error

    expect(User.exists?(user.id)).to be(false)
    expect([ DailyExercise, ApiUsage, JudgeSolve ].map { |model| model.where(user_id: user.id).count }).to eq([ 0, 0, 0 ])
    expect(logged.string).to include("Stopped GenerateDailyExercisesJob for user #{user.id}: the account was deleted")
  end

  it "lets a running regeneration finish its call, then write nothing and stop quietly" do
    exercise = todays_set
    exercise.update!(regenerating_since: Time.current)
    delete_account_during_the_provider_call

    expect { RegenerateExerciseJob.perform_now(user_id: user.id) }.not_to raise_error

    expect(DailyExercise.exists?(exercise.id)).to be(false)
    expect(ApiUsage.where(user_id: user.id).count).to eq(0)
    expect(logged.string).to include("Stopped RegenerateExerciseJob for user #{user.id}: the account was deleted")
  end

  it "stores no review for a review that was running" do
    response = submitted_response(todays_set)
    delete_account_during_the_provider_call

    outcome = ResponseReview.new(response, user: user).call

    expect(outcome.status).to eq(:set_cleared)
    expect([ DailyResponse, ConceptMastery, ApiUsage ].map { |model| model.where(user_id: user.id).count }).to eq([ 0, 0, 0 ])
  end

  it "stores no duck reply that lands after the deletion" do
    exercise = todays_set
    AccountDeletion.call(user)

    outcome = DuckThread.append!(exercise, "code_review", message: "Is it the loop?", answer: "Look at the query.",
                                 expected_version: 0, expected_scope: exercise.draft_scope)

    expect(outcome).to eq(:deleted)
    expect(DuckThread.where(user_id: user.id)).to be_empty
  end

  it "stores no follow-up reply that lands after the deletion" do
    response = submitted_response(todays_set)
    AccountDeletion.call(user)

    expect { response.append_follow_up!("code_review", question: "Why?", answer: "Because.") }.to raise_error(ActiveRecord::RecordNotFound)
    expect(ReviewFollowUp.where(daily_response_id: response.id)).to be_empty
  end

  it "logs, and does not raise, when the usage row for a finished call has no user to point at" do
    AccountDeletion.call(user)

    result = AiService.for(user).send(:call_and_log, user, AiService.request_for("duck_thread", system: "s", prompt: "p", history: []))

    expect(result).to be_present
    expect(ApiUsage.where(user_id: user.id)).to be_empty
    expect(logged.string).to include("[usage] ApiUsage log failed for purpose=duck_thread user_id=#{user.id}")
  end

  it "finds no user in a job enqueued before the deletion, and exits" do
    exercise = todays_set
    exercise.update!(regenerating_since: Time.current)
    user_id = user.id
    AccountDeletion.call(user)

    expect {
      GenerateDailyExercisesJob.perform_now(user_id: user_id)
      GenerateDailyExercisesJob.perform_now(user_id: user_id, scheduled: true)
      RegenerateExerciseJob.perform_now(user_id: user_id)
      SendPushReminderJob.perform_now(user_id: user_id, kind: :nudge)
      GenerateConceptReferenceJob.perform_now(concept: "n_plus_one", language: "ruby_rails", user_id: user_id)
      GenerateRecognitionGuideJob.perform_now(group_key: RecognitionGuide::GROUP_KEYS.first, user_id: user_id)
    }.not_to raise_error
    expect([ DailyExercise, ApiUsage ].map { |model| model.where(user_id: user_id).count }).to eq([ 0, 0 ])
    expect([ ConceptReference.count, RecognitionGuide.count ]).to eq([ 0, 0 ])
  end
end
