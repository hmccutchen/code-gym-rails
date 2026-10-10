require "rails_helper"

RSpec.describe GenerateDailyExercisesJob do
  include ActiveSupport::Testing::TimeHelpers

  let(:user) { User.create!(email: "cronuser@example.com", name: "Cron", provider: "anthropic", api_keys: { "anthropic" => "sk-ant-test" }, time_zone: "UTC") }

  # Examples without travel_to may run on a weekday or weekend, so these stubs answer both paths.
  def stub_provider(u = user, problem_set: { "code_review" => {} })
    judged = AiService::JudgedSet.new(problem_set: problem_set, dropped_sections: [], outcomes: {})
    svc = instance_double(ClaudeService, generate_unjudged_exercise: judged, generate_judged_exercise: judged)
    allow(AiService).to receive(:for).with(u).and_return(svc)
    svc
  end

  def stub_provider_failure(error, message, u = user)
    svc = instance_double(ClaudeService)
    allow(svc).to receive(:generate_unjudged_exercise).and_raise(*[ error, message ].compact)
    allow(svc).to receive(:generate_judged_exercise).and_raise(*[ error, message ].compact)
    allow(AiService).to receive(:for).with(u).and_return(svc)
  end

  describe "the user named in log lines" do
    let(:logged) { StringIO.new }

    before { allow(Rails).to receive(:logger).and_return(ActiveSupport::Logger.new(logged)) }

    def expect_logged_by_id
      expect(logged.string).to include("user #{user.id}")
      expect(logged.string).not_to include(user.email)
    end

    it "names the user by id on success" do
      stub_provider
      described_class.new.perform(user_id: user.id)
      expect_logged_by_id
    end

    [ AiService::Error, AiService::AuthenticationError, AiService::RateLimitError, AiService::TimeoutError ].each do |error|
      it "names the user by id on #{error.name.demodulize}" do
        stub_provider_failure(error, "boom")
        described_class.new.perform(user_id: user.id)
        expect_logged_by_id
      end
    end

    it "names the user by id when a concurrent job already generated the day" do
      stub_provider
      allow(DailyExercise).to receive(:create!).and_raise(ActiveRecord::RecordNotUnique.new("duplicate key"))
      described_class.new.perform(user_id: user.id)
      expect_logged_by_id
    end
  end

  it "creates a DailyExercise from the provider's generated problem set" do
    stub_provider

    described_class.new.perform(user_id: user.id)

    exercise = DailyExercise.find_by(user: user, date: Date.current)
    expect(exercise.problem_set).to eq("code_review" => {})
  end

  it "does not touch last_generation_error fields on success" do
    stub_provider

    described_class.new.perform(user_id: user.id)

    expect(user.reload.last_generation_error_date).to be_nil
    expect(user.last_generation_error).to be_nil
  end

  it "clears a prior failure once generation succeeds" do
    user.update!(last_generation_error_date: Date.current, last_generation_error: "boom")
    stub_provider

    described_class.new.perform(user_id: user.id)

    expect(user.reload.last_generation_error_date).to be_nil
    expect(user.last_generation_error).to be_nil
  end

  it "logs and continues when AiService::Error is raised" do
    stub_provider_failure(AiService::Error, "boom")

    expect(Rails.logger).to receive(:error).with(/Failed to generate exercise.*boom/)
    expect { described_class.new.perform(user_id: user.id) }.not_to raise_error
    expect(DailyExercise.exists?(user: user, date: Date.current)).to be false
  end

  it "records a rejected key as bad_key and renders a Setup-pointing sentence" do
    stub_provider_failure(AiService::AuthenticationError, "invalid x-api-key")

    expect(Rails.logger).to receive(:error).with(/Failed to generate exercise.*\(bad_key\).*invalid x-api-key/)
    described_class.new.perform(user_id: user.id)

    user.reload
    expect(user.last_generation_error_date).to eq(Date.current)
    expect(user.last_generation_failure).to eq("bad_key")
    expect(user.last_generation_failed_at).to be_within(1.minute).of(Time.current)
    expect(user.last_generation_error).to be_nil
    expect(user.generation_failure_message(surface: :generation))
      .to eq("Claude didn't accept your API key, so nothing was generated. Check the key in Setup.")
  end

  it "records a 429 as a short rate limit" do
    stub_provider_failure(AiService::RateLimitError, "rate limited")
    allow(Rails.logger).to receive(:error)

    described_class.new.perform(user_id: user.id)

    expect(user.reload.last_generation_failure).to eq("short_rate_limit")
    expect(user.generation_failure_message(surface: :generation)).to start_with("Claude is limiting requests right now, so nothing was generated.")
  end

  # A key switch before the dashboard reads the failure must not relabel it.
  it "stores the provider tried and its wait, and keeps naming that provider after a switch" do
    error = AiService::RateLimitError.new("rate limited", retry_after: 300).tap { |e| e.provider = "anthropic" }
    stub_provider_failure(error, nil)
    allow(Rails.logger).to receive(:error)

    described_class.new.perform(user_id: user.id)

    user.reload
    expect(user.last_generation_failure_provider).to eq("anthropic")
    expect(user.last_generation_retry_after).to eq(300)
    user.update!(provider: "gemini", api_keys: { "gemini" => "AIzaTestKey" })
    expect(user.generation_failure_message(surface: :generation))
      .to eq("Claude is limiting requests right now, so nothing was generated. Try again in about 5 minutes.")
  end

  it "records a generic AiService::Error as other and never stores its message" do
    stub_provider_failure(AiService::Error, "boom")
    allow(Rails.logger).to receive(:error)

    described_class.new.perform(user_id: user.id)

    user.reload
    expect(user.last_generation_error_date).to eq(Date.current)
    expect(user.last_generation_failure).to eq("other")
    expect(user.last_generation_error).to be_nil
    expect(user.generation_failure_message(surface: :generation)).not_to include("boom")
  end

  it "persists a failure and writes no day when the judge rejects every section" do
    allow_any_instance_of(ClaudeService).to receive(:generate_judged_exercise).and_raise(AiService::AllSectionsRejectedError)
    allow_any_instance_of(ClaudeService).to receive(:generate_unjudged_exercise).and_raise(AiService::AllSectionsRejectedError)
    allow(Rails.logger).to receive(:error)

    described_class.new.perform(user_id: user.id)

    user.reload
    expect(DailyExercise.exists?(user: user, date: Date.current)).to be false
    expect(user.last_generation_error).to eq(AiService::AllSectionsRejectedError.new.message)
  end

  it "persists the failure date in the user's own time zone" do
    pac = User.create!(email: "pac2@example.com", name: "Pac", provider: "anthropic", api_keys: { "anthropic" => "sk-ant-test" }, time_zone: "America/Los_Angeles")
    stub_provider_failure(AiService::Error, "boom", pac)
    allow(Rails.logger).to receive(:error)

    # 2026-07-13 06:00 UTC == 2026-07-12 23:00 PDT — still July 12th in LA.
    travel_to(Time.utc(2026, 7, 13, 6, 0)) do
      described_class.new.perform(user_id: pac.id)
    end

    expect(pac.reload.last_generation_error_date).to eq(Date.new(2026, 7, 12))
  end

  it "persists the resolved language on the created DailyExercise" do
    user.update!(language: "javascript")
    stub_provider

    described_class.new.perform(user_id: user.id)

    exercise = DailyExercise.find_by(user: user, date: Date.current)
    expect(exercise.language).to eq("javascript")
  end

  it "logs and continues when a concurrent job already created today's exercise (unique index race)" do
    stub_provider
    allow(DailyExercise).to receive(:create!).and_raise(
      ActiveRecord::RecordNotUnique.new("duplicate key value violates unique constraint")
    )

    expect(Rails.logger).to receive(:info).with(/Skipped duplicate generation/)
    expect { described_class.new.perform(user_id: user.id) }.not_to raise_error
    expect(user.reload.last_generation_error_date).to be_nil
  end

  it "records a timeout without the socket internals it came from" do
    stub_provider_failure(AiService::TimeoutError, "Network error calling Claude: Net::ReadTimeout with #<TCPSocket:(closed)>")
    allow(Rails.logger).to receive(:error)

    described_class.new.perform(user_id: user.id)

    user.reload
    expect(user.last_generation_error_date).to eq(Date.current)
    expect(user.last_generation_failure).to eq("timeout")
    expect(user.generation_failure_message(surface: :generation))
      .to eq("Claude took too long to answer, so nothing was generated. Try again.")
  end

  # A failure banner above a set a concurrent generation already created would stay all day.
  it "does not persist a failure when today's exercise already exists" do
    DailyExercise.create!(user: user, date: Date.current, problem_set: { "code_review" => {} },
                          generated_at: Time.current, language: "ruby_rails")
    stub_provider_failure(AiService::Error, "boom")
    allow(Rails.logger).to receive(:error)

    described_class.new.send(:generate_for, user)

    expect(user.reload.last_generation_error_date).to be_nil
    expect(user.last_generation_error).to be_nil
  end

  it "clears a stale failure flag when today's exercise already exists" do
    user.update!(last_generation_error_date: Date.current, last_generation_error: "boom")
    DailyExercise.create!(user: user, date: Date.current, problem_set: { "code_review" => {} },
                          generated_at: Time.current, language: "ruby_rails")
    stub_provider_failure(AiService::Error, "boom")
    allow(Rails.logger).to receive(:error)

    described_class.new.send(:generate_for, user)

    expect(user.reload.last_generation_error_date).to be_nil
    expect(user.last_generation_error).to be_nil
  end

  it "writes the plan notes with the row on both paths" do
    notes = { "coverage" => "plan_review", "shared_concept" => "feature_envy" }
    judged = AiService::JudgedSet.new(problem_set: { "code_review" => {} }, dropped_sections: [], outcomes: {},
                                      plan_notes: notes)
    svc = instance_double(ClaudeService, generate_unjudged_exercise: judged, generate_judged_exercise: judged)
    allow(AiService).to receive(:for).with(user).and_return(svc)

    travel_to(Time.utc(2026, 7, 13, 15, 0)) do
      described_class.new.perform(user_id: user.id)
      expect(DailyExercise.find_by(user: user, date: Date.current).plan_notes).to eq(notes)
    end
    travel_to(Time.utc(2026, 7, 18, 15, 0)) do
      described_class.new.perform(user_id: user.id)
      expect(DailyExercise.find_by(user: user, date: Date.current).plan_notes).to eq(notes)
    end
  end

  it "judges on the cron path and records dropped sections" do
    judged_set = AiService::JudgedSet.new(
      problem_set:      { "code_review" => { "question" => "q", "concept" => "n_plus_one" } },
      dropped_sections: [ "pattern" ],
      outcomes:         {}
    )
    fake_service = instance_double(ClaudeService, generate_judged_exercise: judged_set)
    allow(AiService).to receive(:for).with(user).and_return(fake_service)

    travel_to(Time.utc(2026, 7, 13, 15, 0)) do
      described_class.new.perform
      exercise = DailyExercise.find_by(user: user, date: Date.current)
      expect(exercise.dropped_sections).to eq([ "pattern" ])
    end
  end

  it "judges an on-demand generation on a weekday" do
    user.update!(language: "javascript")
    svc = stub_provider
    allow(svc).to receive(:generate_judged_exercise).and_return(
      AiService::JudgedSet.new(problem_set: { "code_review" => {} }, dropped_sections: [ "pattern" ], outcomes: {})
    )

    travel_to(Time.utc(2026, 7, 13, 6, 0)) do
      described_class.new.perform(user_id: user.id)

      expect(svc).to have_received(:generate_judged_exercise).with(user, language: "javascript")
      expect(svc).not_to have_received(:generate_unjudged_exercise)
      expect(DailyExercise.find_by(user: user, date: Date.current).dropped_sections).to eq([ "pattern" ])
    end
  end

  it "does not judge an on-demand generation on a weekend" do
    user.update!(language: "javascript")
    svc = stub_provider
    allow(svc).to receive(:generate_unjudged_exercise).and_return(
      AiService::JudgedSet.new(problem_set: { "code_review" => {} }, dropped_sections: [ "design_comparison" ], outcomes: {})
    )

    travel_to(Time.utc(2026, 7, 18, 12, 0)) do
      described_class.new.perform(user_id: user.id)

      expect(svc).to have_received(:generate_unjudged_exercise).with(user, language: "javascript")
      expect(svc).not_to have_received(:generate_judged_exercise)
      expect(DailyExercise.find_by(user: user, date: Date.current).dropped_sections).to eq([ "design_comparison" ])
    end
  end

  it "skips an anonymized user on the on-demand path" do
    user.anonymize!
    expect(AiService).not_to receive(:for)

    described_class.new.perform(user_id: user.id)

    expect(DailyExercise.exists?(user: user, date: Date.current)).to be false
  end

  describe "hourly batch (no user_id), zone-gated" do
    def stub_generation_for(u)
      judged_set = AiService::JudgedSet.new(problem_set: { "code_review" => {} }, dropped_sections: [], outcomes: {})
      svc = instance_double(ClaudeService, generate_judged_exercise: judged_set, generate_unjudged_exercise: judged_set)
      allow(AiService).to receive(:for).with(u).and_return(svc)
    end

    let(:pac) { User.create!(email: "pac@example.com", name: "Pac", provider: "anthropic", api_keys: { "anthropic" => "sk-ant-test" }, time_zone: "America/Los_Angeles") }

    it "does not generate before 8am local" do
      stub_generation_for(pac)
      travel_to(Time.utc(2026, 7, 13, 14, 0)) do
        described_class.new.perform
        local_today = Time.use_zone("America/Los_Angeles") { Date.current }
        expect(DailyExercise.exists?(user: pac, date: local_today)).to be false
      end
    end

    it "generates at/after 8am local on a weekday" do
      stub_generation_for(pac)
      travel_to(Time.utc(2026, 7, 13, 15, 0)) do
        described_class.new.perform
        local_today = Time.use_zone("America/Los_Angeles") { Date.current }
        expect(DailyExercise.exists?(user: pac, date: local_today)).to be true
      end
    end

    it "does not generate on a local weekend" do
      stub_generation_for(pac)
      travel_to(Time.utc(2026, 7, 18, 17, 0)) do
        described_class.new.perform
        expect(DailyExercise.where(user: pac).count).to eq(0)
      end
    end

    it "creates exactly one exercise when the batch runs twice in the same hour" do
      stub_generation_for(pac)
      travel_to(Time.utc(2026, 7, 13, 15, 0)) do
        described_class.new.perform
        described_class.new.perform
        expect(DailyExercise.where(user: pac).count).to eq(1)
      end
    end

    it "gates each user independently by their own zone within the same batch run" do
      alaska = User.create!(email: "alaska@example.com", name: "Alaska", provider: "anthropic", api_keys: { "anthropic" => "sk-ant-test" }, time_zone: "America/Anchorage")
      stub_generation_for(pac)
      stub_generation_for(alaska)

      travel_to(Time.utc(2026, 7, 13, 15, 0)) do
        described_class.new.perform

        pac_local_today = Time.use_zone("America/Los_Angeles") { Date.current }
        expect(DailyExercise.exists?(user: pac, date: pac_local_today)).to be true

        expect(DailyExercise.where(user: alaska).count).to eq(0)
      end
    end

    it "skips a user who has paused automatic generation" do
      stub_generation_for(pac)
      pac.update!(paused_generation_at: Time.current)

      travel_to(Time.utc(2026, 7, 13, 15, 0)) do
        described_class.new.perform
        local_today = Time.use_zone("America/Los_Angeles") { Date.current }
        expect(DailyExercise.exists?(user: pac, date: local_today)).to be false
      end
    end

    it "still generates for a paused user on the on-demand path" do
      stub_generation_for(pac)
      pac.update!(paused_generation_at: Time.current)

      travel_to(Time.utc(2026, 7, 13, 15, 0)) do
        described_class.new.perform(user_id: pac.id)
        local_today = Time.use_zone("America/Los_Angeles") { Date.current }
        expect(DailyExercise.exists?(user: pac, date: local_today)).to be true
      end
    end
  end

  describe "the push reminder" do
    def stub_generation_for(u)
      judged_set = AiService::JudgedSet.new(problem_set: { "code_review" => {} }, dropped_sections: [], outcomes: {})
      svc = instance_double(ClaudeService, generate_judged_exercise: judged_set, generate_unjudged_exercise: judged_set)
      allow(AiService).to receive(:for).with(u).and_return(svc)
    end

    let(:pac) { User.create!(email: "reminded@example.com", name: "Pac", provider: "anthropic", api_keys: { "anthropic" => "sk-ant-test" }, time_zone: "America/Los_Angeles") }

    it "enqueues one for the batch that generated the set" do
      stub_generation_for(pac)

      travel_to(Time.utc(2026, 7, 13, 15, 0)) do
        expect { described_class.new.perform }
          .to have_enqueued_job(SendPushReminderJob).with(user_id: pac.id).once
      end
    end

    # The cron runs hourly, so a check only inside generate_now would let later runs re-enqueue the nudge.
    it "does not enqueue again on later runs the same day" do
      stub_generation_for(pac)

      travel_to(Time.utc(2026, 7, 13, 15, 0)) { described_class.new.perform }

      travel_to(Time.utc(2026, 7, 13, 16, 0)) do
        expect { described_class.new.perform }.not_to have_enqueued_job(SendPushReminderJob)
      end
    end

    it "does not enqueue for an on-demand generation" do
      stub_generation_for(pac)

      travel_to(Time.utc(2026, 7, 13, 15, 0)) do
        expect { described_class.new.perform(user_id: pac.id) }.not_to have_enqueued_job(SendPushReminderJob)
      end
    end

    it "does not enqueue when the provider failed and no set exists" do
      svc = instance_double(ClaudeService)
      allow(svc).to receive(:generate_judged_exercise).and_raise(AiService::Error, "boom")
      allow(AiService).to receive(:for).with(pac).and_return(svc)

      travel_to(Time.utc(2026, 7, 13, 15, 0)) do
        expect { described_class.new.perform }.not_to have_enqueued_job(SendPushReminderJob)
      end
    end
  end

  describe "the unfinished-set nudge on a later tick" do
    it "nudges when the set exists and nothing has been answered" do
      user.update!(reminder_level: :ready_and_nudges)

      Time.use_zone("UTC") do
        travel_to(Time.zone.local(2026, 9, 8, 14, 0)) do
          DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current,
                                language: "ruby_rails",
                                problem_set: { "code_review" => { "question" => "q" } })

          expect(SendPushReminderJob).to receive(:perform_later).with(user_id: user.id, kind: :nudge)

          described_class.new.perform
        end
      end
    end

    it "nudges a day that was answered in part and then left alone" do
      user.update!(reminder_level: :ready_and_nudges)

      Time.use_zone("UTC") do
        travel_to(Time.zone.local(2026, 9, 8, 11, 0)) do
          exercise = DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current,
                                           language: "ruby_rails",
                                           problem_set: { "code_review" => { "question" => "q" },
                                                          "pattern"     => { "question" => "p" } })
          DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                                answers: { "code_review" => "a genuinely substantive answer here" })
        end

        travel_to(Time.zone.local(2026, 9, 8, 14, 0)) do
          expect(SendPushReminderJob).to receive(:perform_later).with(user_id: user.id, kind: :nudge)

          described_class.new.perform
        end
      end
    end

    it "goes quiet while the answers are still being saved" do
      user.update!(reminder_level: :ready_and_nudges)

      Time.use_zone("UTC") do
        travel_to(Time.zone.local(2026, 9, 8, 14, 0)) do
          exercise = DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current,
                                           language: "ruby_rails",
                                           problem_set: { "code_review" => { "question" => "q" } })
          DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                                answers: { "code_review" => "a genuinely substantive answer here" })

          expect(SendPushReminderJob).not_to receive(:perform_later)

          described_class.new.perform
        end
      end
    end

    it "goes quiet once the day is submitted" do
      user.update!(reminder_level: :ready_and_nudges)

      Time.use_zone("UTC") do
        travel_to(Time.zone.local(2026, 9, 8, 11, 0)) do
          exercise = DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current,
                                           language: "ruby_rails",
                                           problem_set: { "code_review" => { "question" => "q" } })
          DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                                answers: { "code_review" => "a genuinely substantive answer here" },
                                submitted_at: Time.current)
        end

        travel_to(Time.zone.local(2026, 9, 8, 14, 0)) do
          expect(SendPushReminderJob).not_to receive(:perform_later)

          described_class.new.perform
        end
      end
    end

    it "does not regenerate the set it nudges about" do
      user.update!(reminder_level: :ready_and_nudges)

      Time.use_zone("UTC") do
        travel_to(Time.zone.local(2026, 9, 8, 14, 0)) do
          DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current,
                                language: "ruby_rails",
                                problem_set: { "code_review" => { "question" => "q" } })
          allow(SendPushReminderJob).to receive(:perform_later)

          described_class.new.perform

          expect(DailyExercise.where(user: user, date: Date.current).count).to eq(1)
        end
      end
    end
  end
end
