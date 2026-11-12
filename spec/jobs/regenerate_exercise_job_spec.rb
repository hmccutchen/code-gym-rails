require "rails_helper"

RSpec.describe RegenerateExerciseJob, type: :job do
  include ActiveSupport::Testing::TimeHelpers
  include PracticeGenerationHelpers

  let(:user) { create_user_with_key(email: "regen-job@example.com") }

  around do |example|
    next example.run if example.metadata[:own_clock]

    travel_to(Time.utc(2026, 10, 14, 15, 0, 0)) { example.run }
  end

  def claimed_exercise
    DailyExercise.create!(user: user, date: Date.current, generated_at: 1.hour.ago,
                          language: "ruby_rails",
                          problem_set: { "code_review" => { "question" => "old" } },
                          regenerating_since: Time.current)
  end

  def judged_set(problem_set, dropped: [])
    AiService::JudgedSet.new(problem_set: problem_set, dropped_sections: dropped, outcomes: {}, plan_notes: {})
  end

  def stub_provider(result)
    fake_service = instance_double(ClaudeService)
    allow(AiService).to receive(:for).with(user).and_return(fake_service)
    if result.is_a?(StandardError)
      allow(fake_service).to receive(:generate_judged_exercise).and_raise(result)
    else
      allow(fake_service).to receive(:generate_judged_exercise) do |caller, language:, schedule_context:, **|
        with_practice_context(judged_set(result), user: caller, language: language, schedule_context: schedule_context)
      end
    end

    fake_service
  end

  describe "the count of account failures that holds the schedule" do
    it "is left alone when a regeneration's key is rejected, since today's set exists and its nudges still need the schedule" do
      claimed_exercise
      stub_provider(ProviderError::AuthenticationError.new("401 invalid x-api-key"))
      allow(Rails.logger).to receive(:error)

      2.times { described_class.new.perform(user_id: user.id) }

      expect(user.reload).to have_attributes(last_generation_failure: "bad_key", generation_account_failures: 0)
      expect(ScheduledGeneration.users).to include(user)
    end

    it "goes back to zero when a regeneration succeeds, since a generation the user started worked" do
      claimed_exercise
      user.update_columns(generation_account_failures: KeyHold::AFTER)
      stub_provider({ "code_review" => { "question" => "new" } })

      described_class.new.perform(user_id: user.id)

      expect(user.reload.generation_account_failures).to eq(0)
    end
  end

  describe "a key that changes while a regeneration is calling the provider" do
    def provider_raising_after(error)
      service = instance_double(ClaudeService)
      allow(service).to receive(:generate_judged_exercise) do |*|
        yield
        raise error
      end
      allow(AiService).to receive(:for).with(user).and_return(service)
      allow(Rails.logger).to receive(:error)
    end

    def remove_key_in_use = User.find(user.id).tap { |fresh| fresh.remove_api_key(fresh.provider) }.save!

    before { user.update!(api_keys: user.api_keys.merge("openai" => "sk-proj-Ab8RN6J5yPUsY9SwLxAS2DYq")) }

    it "records no failure for a key removed during the call, keeps the set and releases the claim" do
      exercise = claimed_exercise
      provider_raising_after(ProviderError::AuthenticationError.new("401 invalid x-api-key")) { remove_key_in_use }

      described_class.new.perform(user_id: user.id)

      expect(user.reload).to have_attributes(provider: "openai", generation_failed_today?: false, last_generation_failure: nil,
                                             last_generation_failure_provider: nil)
      expect(exercise.reload).to have_attributes(regenerating_since: nil, regenerated_at: nil)
      expect(exercise.problem_set).to eq("code_review" => { "question" => "old" })
    end

    it "records no setup failure for a key removed during the call" do
      claimed_exercise
      provider_raising_after(SetupError.new("unsupported language")) { remove_key_in_use }

      described_class.new.perform(user_id: user.id)

      expect(user.reload.generation_failed_today?).to be(false)
    end

    it "records the failure as today's when the key in use did not change" do
      claimed_exercise
      provider_raising_after(ProviderError::AuthenticationError.new("401 invalid x-api-key")) { User.find(user.id).update!(language: "javascript") }

      described_class.new.perform(user_id: user.id)

      expect(user.reload).to have_attributes(generation_failed_today?: true, last_generation_failure: "bad_key",
                                             last_generation_failure_provider: "anthropic")
    end

    it "still says why the set was kept when every section failed its check, whichever key wrote the drafts" do
      claimed_exercise
      provider_raising_after(ProviderError::AllSectionsRejectedError.new("all rejected")) { remove_key_in_use }

      described_class.new.perform(user_id: user.id)

      expect(user.reload.last_generation_error).to eq(RegenerateExerciseJob::KEPT_SET_MESSAGES.fetch(:all_rejected))
    end
  end

  it "keeps the old inactive set, draft and notes after settings change during one paid call" do
      stub_const("PracticePolicyMode::INITIATE_PRACTICE_POLICY", false)
      exercise = claimed_exercise
      exercise.update!(plan_notes: { "size" => 2, "daily_kinds" => DailyKinds::DEFAULT.map(&:key) })
      draft = user.daily_responses.create!(date: exercise.date, daily_exercise: exercise,
        answers: { "code_review" => "Keep my unsent work" })
      old_set = exercise.attributes.except("regenerating_since", "updated_at")
      old_draft = draft.attributes
      service = stub_provider({})
      expect(service).to receive(:generate_judged_exercise).once do |_caller, language:, deadline:, schedule_context:|
        expect(schedule_context[:active]).to be(false)
        expect(language).to eq(exercise.language)
        expect(deadline).to be_a(GenerationDeadline)
        User.find(user.id).update!(daily_section_count: 2)
        judged_set({ "code_review" => { "question" => "paid replacement" } }).with(schedule_context: schedule_context)
      end
      described_class.new.perform(user_id: user.id)
      expect(exercise.reload.attributes.except("regenerating_since", "updated_at")).to eq(old_set)
      expect(exercise.regenerating_since).to be_nil
      expect(draft.reload.attributes).to eq(old_draft)
      expect(user.reload.daily_section_count).to eq(2)
      expect(user.last_generation_error).to be_nil
    end

  describe "the user named in log lines, by id since an email in a log is personal data nobody deletes" do
    let(:logged) { StringIO.new }

    before { allow(Rails).to receive(:logger).and_return(ActiveSupport::Logger.new(logged)) }

    def expect_logged_by_id
      expect(logged.string).to include("user #{user.id}")
      expect(logged.string).not_to include(user.email)
    end

    it "names the user by id on success" do
      claimed_exercise
      stub_provider({ "code_review" => { "question" => "new" } })
      described_class.new.perform(user_id: user.id)
      expect_logged_by_id
    end

    it "names the user by id on failure" do
      claimed_exercise
      stub_provider(ProviderError.new("boom"))
      described_class.new.perform(user_id: user.id)
      expect_logged_by_id
    end

    it "names the user by id when the claim was released under the call" do
      exercise = claimed_exercise
      fake_service = instance_double(ClaudeService)
      allow(AiService).to receive(:for).with(user).and_return(fake_service)
      allow(fake_service).to receive(:generate_judged_exercise) do |caller, language:, schedule_context:, **|
        result = with_practice_context(judged_set({ "code_review" => { "question" => "new" } }),
          user: caller, language: language, schedule_context: schedule_context)
        exercise.update_columns(regenerating_since: nil)
        result
      end
      described_class.new.perform(user_id: user.id)
      expect_logged_by_id
    end

    { "reviewed" => { ai_review: { "code_review" => { "rating" => "developing" } } },
      "being reviewed" => { reviewing_since: 10.seconds.ago } }.each do |state, attributes|
      it "names the user by id when today's #{state} set is kept" do
        exercise = claimed_exercise
        DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                              submitted_at: Time.current, answers: { "code_review" => "a" * 20 }, **attributes)
        stub_provider({ "code_review" => { "question" => "new" } })
        described_class.new.perform(user_id: user.id)
        expect_logged_by_id
      end
    end
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

  it "clears the sections the judge dropped from the day it replaces" do
    exercise = claimed_exercise
    exercise.update!(dropped_sections: [ "pattern" ])
    stub_provider({ "code_review" => { "question" => "new" } })

    described_class.new.perform(user_id: user.id)

    expect(exercise.reload.dropped_sections).to eq([])
  end

  it "rewrites the plan notes from the new plan rather than keeping the old day's" do
    exercise = claimed_exercise
    exercise.update!(plan_notes: { "coverage" => "plan_review", "shared_concept" => "feature_envy" })
    fake_service = instance_double(ClaudeService)
    allow(AiService).to receive(:for).with(user).and_return(fake_service)
    allow(fake_service).to receive(:generate_judged_exercise) do |caller, language:, schedule_context:, **|
      result = judged_set({ "code_review" => { "question" => "new" } }).with(plan_notes: { "shared_concept" => "long_method" })
      with_practice_context(result, user: caller, language: language, schedule_context: schedule_context)
    end

    described_class.new.perform(user_id: user.id)

    expect(exercise.reload.plan_notes).to eq("shared_concept" => "long_method")
  end

  it "clears the plan notes when the new plan recorded none" do
    exercise = claimed_exercise
    exercise.update!(plan_notes: { "coverage" => "plan_review" })
    stub_provider({ "code_review" => { "question" => "new" } })

    described_class.new.perform(user_id: user.id)

    expect(exercise.reload.plan_notes).to eq({})
  end

  # User#carry_forward can clear the claim mid-call; the job must then discard its set and keep the draft.
  it "abandons the regeneration when its claim was released during the provider call" do
    exercise = claimed_exercise
    draft = DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                                  answers: { "code_review" => "a draft worth keeping here" })
    fake_service = instance_double(ClaudeService)
    allow(AiService).to receive(:for).with(user).and_return(fake_service)
    allow(fake_service).to receive(:generate_judged_exercise) do |caller, language:, schedule_context:, **|
      result = with_practice_context(judged_set({ "code_review" => { "question" => "new" } }),
        user: caller, language: language, schedule_context: schedule_context)
      exercise.update_columns(regenerating_since: nil)
      result
    end

    described_class.new.perform(user_id: user.id)

    expect(exercise.reload.problem_set).to eq("code_review" => { "question" => "old" })
    expect(exercise.regenerated_at).to be_nil
    expect(draft.reload).to be_persisted
    expect(user.reload.last_generation_error).to be_nil
  end

  # The claim is matched by timestamp, so a newer claim from a later click is not mistaken for this job's.
  it "abandons the regeneration when a newer claim replaced its own, and leaves that claim standing" do
    exercise = claimed_exercise
    original_claim = exercise.regenerating_since
    newer_claim = original_claim + 90.seconds
    draft = DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                                  answers: { "code_review" => "a draft worth keeping here" })
    fake_service = instance_double(ClaudeService)
    allow(AiService).to receive(:for).with(user).and_return(fake_service)
    allow(fake_service).to receive(:generate_judged_exercise) do |caller, language:, schedule_context:, **|
      result = with_practice_context(judged_set({ "code_review" => { "question" => "new" } }),
        user: caller, language: language, schedule_context: schedule_context)
      exercise.update_columns(regenerating_since: newer_claim)
      result
    end

    described_class.new.perform(user_id: user.id)

    expect(exercise.reload.problem_set).to eq("code_review" => { "question" => "old" })
    expect(exercise.regenerating_since).to be_within(1.second).of(newer_claim)
    expect(draft.reload).to be_persisted
  end

  it "leaves a newer claim standing when its own attempt fails" do
    exercise = claimed_exercise
    newer_claim = exercise.regenerating_since + 90.seconds
    fake_service = instance_double(ClaudeService)
    allow(AiService).to receive(:for).with(user).and_return(fake_service)
    allow(fake_service).to receive(:generate_judged_exercise) do
      exercise.update_columns(regenerating_since: newer_claim)
      raise ProviderError::TimeoutError, "slow"
    end

    described_class.new.perform(user_id: user.id)

    expect(exercise.reload.regenerating_since).to be_within(1.second).of(newer_claim)
  end

  it "destroys the existing response so the new set starts clean" do
    exercise = claimed_exercise
    DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                          answers: { "code_review" => "a" * 20 })
    stub_provider({ "code_review" => { "question" => "new" } })

    described_class.new.perform(user_id: user.id)

    expect(exercise.reload.daily_response).to be_nil
  end

  # A review can land after the controller's check; destroying it would orphan ConceptMastery's movement.
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

  it "distinguishes a review still running from one that landed" do
    exercise = claimed_exercise
    DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                          submitted_at: Time.current, answers: { "code_review" => "a" * 20 },
                          reviewing_since: 10.seconds.ago)
    stub_provider({ "code_review" => { "question" => "new" } })

    described_class.new.perform(user_id: user.id)

    expect(user.reload.last_generation_error).to eq(described_class::KEPT_SET_MESSAGES.fetch(:reviewing))
    expect(user.last_generation_error).not_to include("landed")
  end

  # A claimed response is a review in flight; destroying it discards work the user paid for.
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

  # A load followed by lock! would raise for a deleted row and strand the claim until it goes stale.
  it "completes cleanly when the response is deleted while the provider call runs" do
    exercise = claimed_exercise
    daily_response = DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                                           answers: { "code_review" => "a" * 20 })
    fake_service = stub_provider({ "code_review" => { "question" => "new" } })
    allow(fake_service).to receive(:generate_judged_exercise) do |caller, language:, schedule_context:, **|
      result = with_practice_context(judged_set({ "code_review" => { "question" => "new" } }),
        user: caller, language: language, schedule_context: schedule_context)
      daily_response.destroy
      result
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

    expect(fake_service).to have_received(:generate_judged_exercise).with(user, hash_including(language: "javascript"))
  end

  it "records a section the provider returned unusable as dropped" do
    exercise = claimed_exercise
    stub_provider({ "code_review" => { "question" => "new" } })
    allow(AiService.for(user)).to receive(:generate_judged_exercise) do |caller, language:, schedule_context:, **|
      with_practice_context(judged_set({ "code_review" => { "question" => "new" } }, dropped: [ "design_comparison" ]),
        user: caller, language: language, schedule_context: schedule_context)
    end

    described_class.new.perform(user_id: user.id)

    expect(exercise.reload.dropped_sections).to eq([ "design_comparison" ])
  end

  it "preserves the existing set and the daily allowance when the provider fails" do
    exercise = claimed_exercise
    stub_provider(ProviderError.new("boom"))

    described_class.new.perform(user_id: user.id)

    exercise.reload
    expect(exercise.problem_set).to eq("code_review" => { "question" => "old" })
    expect(exercise.regenerated_at).to be_nil
    expect(exercise.regenerating_since).to be_nil
    expect(user.reload.last_generation_failure).to eq("other")
    expect(user.last_generation_error).to be_nil
    expect(user.last_generation_error_date).to eq(Date.current)
  end

  it "releases the claim and records a setup failure, keeping the old set" do
    exercise = claimed_exercise
    allow(AiService).to receive(:for).with(user).and_raise(SetupError, "User #{user.id} has no recognized AI provider configured")

    expect { described_class.new.perform(user_id: user.id) }.not_to raise_error
    expect(exercise.reload.regenerating_since).to be_nil
    expect(exercise.problem_set).to eq("code_review" => { "question" => "old" })
    expect(user.reload.last_generation_failure).to eq("setup")
  end

  it "records a setup failure for a user whose stored provider is unknown, with no stubbed provider" do
    exercise = claimed_exercise
    user.update_columns(provider: "nonsense")

    expect { described_class.new.perform(user_id: user.id) }.not_to raise_error
    expect(exercise.reload.regenerating_since).to be_nil
    expect(user.reload.last_generation_failure).to eq("setup")
  end

  it "does not raise when the provider fails" do
    claimed_exercise
    stub_provider(ProviderError.new("boom"))

    expect { described_class.new.perform(user_id: user.id) }.not_to raise_error
  end

  it "records a rejected key as bad_key and renders it in the user's words, not the provider's" do
    claimed_exercise
    stub_provider(ProviderError::AuthenticationError.new("401 invalid x-api-key"))

    described_class.new.perform(user_id: user.id)

    expect(user.reload.last_generation_failure).to eq("bad_key")
    expect(user.generation_failure_message(surface: :regeneration))
      .to eq("Claude didn't accept your API key, so the new set wasn't generated. Check the key in Setup.")
  end

  it "records rate limiting as a short limit, not a configuration problem" do
    claimed_exercise
    stub_provider(ProviderError::RateLimitError.new("rate limited"))

    described_class.new.perform(user_id: user.id)

    expect(user.reload.last_generation_failure).to eq("short_rate_limit")
  end

  it "stores the provider tried and its wait, so the line survives a key switch" do
    claimed_exercise
    stub_provider(ProviderError::RateLimitError.new("rate limited", retry_after: 120).tap { |e| e.provider = "anthropic" })

    described_class.new.perform(user_id: user.id)

    expect(user.reload).to have_attributes(last_generation_failure_provider: "anthropic", last_generation_retry_after: 120)
    user.update!(provider: "gemini", api_keys: { "gemini" => "AIzaTestKey" })
    expect(user.generation_failure_message(surface: :regeneration))
      .to eq("Claude is limiting requests right now, so the new set wasn't generated. Try again in about 2 minutes.")
    user.clear_generation_failure!
    expect(user).to have_attributes(last_generation_failure_provider: nil, last_generation_retry_after: nil)
  end

  it "records a timeout without leaking the socket internals it came from" do
    claimed_exercise
    stub_provider(ProviderError::TimeoutError.new("Network error calling Claude: Net::ReadTimeout with #<TCPSocket:(closed)>"))

    described_class.new.perform(user_id: user.id)

    expect(user.reload.last_generation_failure).to eq("timeout")
    expect(user.generation_failure_message(surface: :regeneration)).not_to include("TCPSocket")
  end

  it "preserves the existing response when the provider fails" do
    exercise = claimed_exercise
    daily_response = DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                                           answers: { "code_review" => "important work" })
    stub_provider(ProviderError.new("timeout"))

    described_class.new.perform(user_id: user.id)

    expect(DailyResponse.exists?(daily_response.id)).to be(true)
    expect(daily_response.reload.answers).to eq("code_review" => "important work")
  end

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

  it "regenerates a weekend set judged, as a weekend set is generated", :own_clock do
    travel_to Time.utc(2026, 10, 17, 15, 0, 0) do
      claimed_exercise
      fake_service = stub_provider({ "code_review" => { "question" => "new" } })

      described_class.new.perform(user_id: user.id)

      expect(fake_service).to have_received(:generate_judged_exercise)
        .with(user, hash_including(deadline: an_instance_of(GenerationDeadline)))
    end
  end

  it "hands the provider a deadline measured from the claim, not from when the job started" do
    exercise = claimed_exercise
    exercise.update_column(:regenerating_since, 2.minutes.ago)
    claim = exercise.reload.regenerating_since
    fake_service = stub_provider({ "code_review" => { "question" => "new" } })
    handed = nil
    allow(fake_service).to receive(:generate_judged_exercise) do |caller, deadline:, language:, schedule_context:|
      handed = deadline
      with_practice_context(judged_set({ "code_review" => { "question" => "new" } }),
        user: caller, language: language, schedule_context: schedule_context)
    end

    described_class.new.perform(user_id: user.id)

    expect(handed.ends_at).to eq(claim + DailyExercise::REGENERATION_DEADLINE)
  end

  it "keeps today's set and the day's regeneration when the deadline leaves no time to draft" do
    exercise = claimed_exercise
    stub_provider(ProviderError::DeadlineError.new("generate_exercise"))

    described_class.new.perform(user_id: user.id)

    exercise.reload
    expect(exercise.problem_set).to eq("code_review" => { "question" => "old" })
    expect(exercise.regenerating_since).to be_nil
    expect(exercise.regenerated_at).to be_nil
    expect(user.reload.last_generation_failure).to eq("timeout")
  end

  it "keeps today's set when the judge rejected every section of the new one, and says so" do
    exercise = claimed_exercise
    stub_provider(ProviderError::AllSectionsRejectedError.new)

    described_class.new.perform(user_id: user.id)

    exercise.reload
    expect(exercise.problem_set).to eq("code_review" => { "question" => "old" })
    expect(exercise.regenerating_since).to be_nil
    expect(exercise.regenerated_at).to be_nil
    expect(user.reload.last_generation_error).to eq(described_class::KEPT_SET_MESSAGES.fetch(:all_rejected))
  end

  it "resolves today in the user's own time zone", :own_clock do
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

  describe "the judge's solves" do
    let(:logged) { StringIO.new }

    def stub_judged(solves, &before_return)
      judged = AiService::JudgedSet.new(problem_set: { "code_review" => { "question" => "new" } }, dropped_sections: [],
                                        outcomes: {}, plan_notes: {}, solves: solves)
      fake_service = instance_double(ClaudeService)
      allow(fake_service).to receive(:model_for).with("generate_exercise").and_return("claude-opus-5-5")
      allow(fake_service).to receive(:generate_judged_exercise) do |caller, language:, schedule_context:, **|
        result = with_practice_context(judged, user: caller, language: language, schedule_context: schedule_context)
        before_return&.call
        result
      end
      allow(AiService).to receive(:for).with(user).and_return(fake_service)
    end

    it "adds the new set's solves as a group of their own and keeps the replaced set's" do
      exercise = claimed_exercise
      old_generated_at = exercise.generated_at
      JudgeSolve.record!(exercise, [ live_solve ])
      stub_judged([ live_solve(judge_pick: "a", matched: false) ])

      described_class.new.perform(user_id: user.id)

      exercise.reload
      expect(exercise.judge_solves.group(:set_generated_at).count.keys)
        .to contain_exactly(be_within(1.second).of(old_generated_at), be_within(1.second).of(exercise.generated_at))
      expect(exercise.judge_solves.find_by(set_generated_at: exercise.generated_at))
        .to have_attributes(matched: false, source: "live", draft_model: "claude-opus-5-5")
    end

    it "lets a review of the new set show the new set's records and never the replaced set's" do
      exercise = claimed_exercise
      replaced = JudgeSolve.record!(exercise, [ live_solve ]).sole
      stub_judged([ live_solve(judge_pick: "a", matched: false) ])

      described_class.new.perform(user_id: user.id)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current, submitted_at: Time.current,
                            answers: { "design_comparison" => "a" * 20 },
                            ai_review: { "design_comparison" => { "rating" => "solid" } })

      expect(JudgeSolve.readable).to contain_exactly(have_attributes(set_generated_at: exercise.reload.generated_at))
      expect(JudgeSolve.readable).not_to include(replaced)
    end

    it "writes nothing when its claim was released under the call" do
      exercise = claimed_exercise
      stub_judged([ live_solve ]) { exercise.update_columns(regenerating_since: nil) }

      described_class.new.perform(user_id: user.id)

      expect(JudgeSolve.count).to eq(0)
    end

    it "writes nothing when a reviewed response keeps today's set" do
      exercise = claimed_exercise
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current, submitted_at: Time.current,
                            answers: { "code_review" => "a" * 20 }, ai_review: { "code_review" => { "rating" => "developing" } })
      stub_judged([ live_solve ])

      described_class.new.perform(user_id: user.id)

      expect(JudgeSolve.count).to eq(0)
    end

    it "writes them for a weekend set too, which is judged like a weekday's", :own_clock do
      travel_to Time.utc(2026, 10, 17, 15, 0, 0) do
        claimed_exercise
        stub_judged([ live_solve ])

        described_class.new.perform(user_id: user.id)

        expect(JudgeSolve.count).to eq(1)
      end
    end

    it "keeps the new set when a record is refused, and logs the refusal without the section or its key" do
      exercise = claimed_exercise
      stub_judged([ live_solve(revert_reason: "judge_failed") ])
      allow(Rails).to receive(:logger).and_return(ActiveSupport::Logger.new(logged))

      described_class.new.perform(user_id: user.id)

      expect(exercise.reload.problem_set).to eq("code_review" => { "question" => "new" })
      expect(exercise.regenerating_since).to be_nil
      expect(JudgeSolve.count).to eq(0)
      expect(logged.string).to include("[judge_solves_record_failed] user=#{user.id} exercise=#{exercise.id} reason=")
      expect(logged.string).not_to include("SECRET", "Which fits?", "a = 1")
    end
  end
end
