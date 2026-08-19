require "rails_helper"

RSpec.describe RegenerateExerciseJob, type: :job do
  include ActiveSupport::Testing::TimeHelpers

  let(:user) { create_user_with_key(email: "regen-job@example.com") }

  def claimed_exercise
    DailyExercise.create!(user: user, date: Date.current, generated_at: 1.hour.ago,
                          language: "ruby_rails",
                          problem_set: { "code_review" => { "question" => "old" } },
                          regenerating_since: Time.current)
  end

  def stub_provider(result)
    fake_service = instance_double(ClaudeService)
    allow(AiService).to receive(:for).with(user).and_return(fake_service)
    if result.is_a?(StandardError)
      allow(fake_service).to receive(:generate_exercise).and_raise(result)
    else
      allow(fake_service).to receive(:generate_exercise).and_return(result)
    end
    fake_service
  end

  it "replaces the problem set in place and releases the claim" do
    exercise = claimed_exercise
    stub_provider({ "code_review" => { "question" => "new" } })

    described_class.new.perform(user_id: user.id)

    exercise.reload
    expect(exercise.problem_set).to eq("code_review" => { "question" => "new" })
    expect(exercise.regenerated_at).to be_present
    expect(exercise.regenerating_since).to be_nil
  end

  it "destroys the existing response so the new set starts clean" do
    exercise = claimed_exercise
    DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                          answers: { "code_review" => "a" * 20 })
    stub_provider({ "code_review" => { "question" => "new" } })

    described_class.new.perform(user_id: user.id)

    expect(exercise.reload.daily_response).to be_nil
  end

  # DailyExercisesController#regenerate refuses a reviewed set, but that check
  # runs a worker hop and a provider call before this destroy — a review started
  # in another tab can land inside that window. Here the whole regeneration is
  # abandoned instead, since the alternative destroys a review ConceptMastery has
  # already recorded tier/streak/retention movement from.
  it "keeps a response reviewed after the click, and the set that review describes" do
    exercise = claimed_exercise
    reviewed = DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                                     submitted_at: Time.current, answers: { "code_review" => "a" * 20 },
                                     ai_review: { "code_review" => { "rating" => "developing" } })
    stub_provider({ "code_review" => { "question" => "new" } })

    described_class.new.perform(user_id: user.id)

    expect(DailyResponse.exists?(reviewed.id)).to be true
    expect(reviewed.reload.ai_review).to eq("code_review" => { "rating" => "developing" })
    expect(exercise.reload.problem_set).to eq("code_review" => { "question" => "old" })
  end

  it "leaves the day's regeneration available after keeping a reviewed set" do
    exercise = claimed_exercise
    DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                          submitted_at: Time.current, answers: { "code_review" => "a" * 20 },
                          ai_review: { "code_review" => { "rating" => "developing" } })
    stub_provider({ "code_review" => { "question" => "new" } })

    described_class.new.perform(user_id: user.id)

    exercise.reload
    expect(exercise.regenerated_at).to be_nil
    expect(exercise.regenerating_since).to be_nil
    expect(user.reload.last_generation_error).to include("today's reviewed set was kept")
    expect(user.last_generation_error_date).to eq(Date.current)
  end

  # The review's own writes commit after its provider call returns, so a claimed
  # row is a review in flight — destroying it discards work the user has paid for.
  it "keeps a response whose review is still in flight" do
    exercise = claimed_exercise
    in_flight = DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                                      submitted_at: Time.current, answers: { "code_review" => "a" * 20 },
                                      reviewing_since: 10.seconds.ago)
    stub_provider({ "code_review" => { "question" => "new" } })

    described_class.new.perform(user_id: user.id)

    expect(DailyResponse.exists?(in_flight.id)).to be true
    expect(exercise.reload.problem_set).to eq("code_review" => { "question" => "old" })
  end

  it "regenerates past an abandoned review claim" do
    exercise = claimed_exercise
    abandoned = DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                                      submitted_at: Time.current, answers: { "code_review" => "a" * 20 },
                                      reviewing_since: (DailyResponse::REVIEW_CLAIM_STALE_AFTER + 1.minute).ago)
    stub_provider({ "code_review" => { "question" => "new" } })

    described_class.new.perform(user_id: user.id)

    expect(DailyResponse.exists?(abandoned.id)).to be false
    expect(exercise.reload.problem_set).to eq("code_review" => { "question" => "new" })
  end

  # #start_over can delete the row while this job is mid-flight. The locked read
  # returns nil for a row already gone rather than raising the way a load
  # followed by #lock! does — a raise here escapes every rescue below and
  # strands the claim until it goes stale.
  it "completes cleanly when the response is deleted while the provider call runs" do
    exercise = claimed_exercise
    daily_response = DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                                           answers: { "code_review" => "a" * 20 })
    fake_service = stub_provider({ "code_review" => { "question" => "new" } })
    allow(fake_service).to receive(:generate_exercise) do
      daily_response.destroy
      { "code_review" => { "question" => "new" } }
    end

    expect { described_class.new.perform(user_id: user.id) }.not_to raise_error

    exercise.reload
    expect(exercise.problem_set).to eq("code_review" => { "question" => "new" })
    expect(exercise.regenerating_since).to be_nil
    expect(exercise.regenerated_at).to be_present
  end

  it "regenerates in the exercise's own stored language" do
    exercise = claimed_exercise
    exercise.update!(language: "javascript")
    fake_service = stub_provider({ "code_review" => { "question" => "new" } })

    described_class.new.perform(user_id: user.id)

    expect(fake_service).to have_received(:generate_exercise).with(user, language: "javascript")
  end

  # The whole point of regenerating in place: a provider failure must not cost
  # the user the set they already have, nor their one regenerate for the day.
  it "preserves the existing set and the daily allowance when the provider fails" do
    exercise = claimed_exercise
    stub_provider(AiService::Error.new("boom"))

    described_class.new.perform(user_id: user.id)

    exercise.reload
    expect(exercise.problem_set).to eq("code_review" => { "question" => "old" })
    expect(exercise.regenerated_at).to be_nil
    expect(exercise.regenerating_since).to be_nil
    expect(user.reload.last_generation_error).to eq("boom")
    expect(user.last_generation_error_date).to eq(Date.current)
  end

  it "does not raise when the provider fails" do
    claimed_exercise
    stub_provider(AiService::Error.new("boom"))

    expect { described_class.new.perform(user_id: user.id) }.not_to raise_error
  end

  it "reports a rejected key in the user's language, not the provider's" do
    claimed_exercise
    stub_provider(AiService::AuthenticationError.new("401 invalid x-api-key"))

    described_class.new.perform(user_id: user.id)

    expect(user.reload.last_generation_error).to eq("Your API key was rejected — check it in Settings.")
    expect(user.last_generation_error).not_to include("x-api-key")
  end

  it "reports rate limiting as a try-again, not a configuration problem" do
    claimed_exercise
    stub_provider(AiService::RateLimitError.new("rate limited"))

    described_class.new.perform(user_id: user.id)

    expect(user.reload.last_generation_error)
      .to eq("The AI provider is rate-limiting requests — try again shortly.")
  end

  it "reports a timeout without leaking the socket internals it came from" do
    claimed_exercise
    stub_provider(AiService::TimeoutError.new("Network error calling Claude: Net::ReadTimeout with #<TCPSocket:(closed)>"))

    described_class.new.perform(user_id: user.id)

    expect(user.reload.last_generation_error)
      .to eq("Generation took longer than the provider's budget — try again.")
    expect(user.last_generation_error).not_to include("TCPSocket")
  end

  it "preserves the existing response when the provider fails" do
    exercise = claimed_exercise
    daily_response = DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                                           answers: { "code_review" => "important work" })
    stub_provider(AiService::Error.new("timeout"))

    described_class.new.perform(user_id: user.id)

    expect(DailyResponse.exists?(daily_response.id)).to be(true)
    expect(daily_response.reload.answers).to eq("code_review" => "important work")
  end

  # A nil problem_set fails DailyExercise's presence validation, so exercise.update!
  # raises inside the transaction after the response has already been destroyed.
  # Without the transaction the user would lose their answers to a bad payload.
  it "rolls back the destroyed response when the replacement set is invalid" do
    exercise = claimed_exercise
    daily_response = DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                                           answers: { "code_review" => "important work" })
    stub_provider(nil)

    described_class.new.perform(user_id: user.id)

    expect(DailyResponse.exists?(daily_response.id)).to be(true)
    expect(daily_response.reload.answers).to eq("code_review" => "important work")
    exercise.reload
    expect(exercise.regenerated_at).to be_nil
    expect(exercise.regenerating_since).to be_nil
    expect(exercise.problem_set).to eq("code_review" => { "question" => "old" })
    expect(user.reload.last_generation_error).to eq("Generation returned an unusable set — try again.")
  end

  it "clears a prior failure once regeneration succeeds" do
    user.update!(last_generation_error_date: Date.current, last_generation_error: "boom")
    claimed_exercise
    stub_provider({ "code_review" => { "question" => "new" } })

    described_class.new.perform(user_id: user.id)

    expect(user.reload.last_generation_error).to be_nil
    expect(user.last_generation_error_date).to be_nil
  end

  # Without the claim there is nothing to finish, so a stray or duplicated job
  # must not spend a second provider call replacing a set nobody asked about.
  it "does nothing when no claim is held" do
    exercise = claimed_exercise
    exercise.update!(regenerating_since: nil)
    allow(AiService).to receive(:for)

    described_class.new.perform(user_id: user.id)

    expect(AiService).not_to have_received(:for)
    expect(exercise.reload.problem_set).to eq("code_review" => { "question" => "old" })
  end

  it "skips an anonymized user" do
    claimed_exercise
    user.anonymize!
    allow(AiService).to receive(:for)

    described_class.new.perform(user_id: user.id)

    expect(AiService).not_to have_received(:for)
  end

  # Date.current must mean the user's today, not the server's, or a user west of
  # UTC regenerates a row dated tomorrow.
  it "resolves today in the user's own time zone" do
    user.update!(time_zone: "Hawaii")
    travel_to Time.utc(2026, 8, 7, 5, 0, 0) do
      exercise = DailyExercise.create!(user: user, date: Date.new(2026, 8, 6),
                                       generated_at: 1.hour.ago,
                                       problem_set: { "code_review" => { "question" => "old" } },
                                       regenerating_since: Time.current)
      stub_provider({ "code_review" => { "question" => "new" } })

      described_class.new.perform(user_id: user.id)

      expect(exercise.reload.problem_set).to eq("code_review" => { "question" => "new" })
    end
  end
end
