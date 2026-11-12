require "rails_helper"

RSpec.describe EnqueueDueGenerationsJob do
  include ActiveSupport::Testing::TimeHelpers
  include ActiveJob::TestHelper

  let(:user) { User.create!(email: "cronuser@example.com", provider: "anthropic", api_keys: { "anthropic" => "sk-ant-test" }, time_zone: "UTC") }

  describe "handing out the sets that are due" do
    let!(:pac) { User.create!(email: "pac@example.com", provider: "anthropic", api_keys: { "anthropic" => "sk-ant-test" }, time_zone: "America/Los_Angeles") }

    def stub_provider(for_user)
      instance_double(ClaudeService, generate_judged_exercise: nil).tap do |service|
        allow(AiService).to receive(:for).with(for_user).and_return(service)
      end
    end

    def scheduled_job_for(account) = have_enqueued_job(GenerateDailyExercisesJob).with(user_id: account.id, scheduled: true)

    def stub_enqueue_for(account, &outcome)
      configured = GenerateDailyExercisesJob.set(priority: JobPriority::SCHEDULED)
      allow(GenerateDailyExercisesJob).to receive(:set).and_return(configured)
      allow(configured).to receive(:perform_later).and_call_original
      allow(configured).to receive(:perform_later).with(user_id: account.id, scheduled: true, &outcome)
    end

    it "runs on the general queue, since it calls no provider" do
      expect(described_class.queue_name).to eq("default")
    end

    it "logs any error one account raises and still enqueues the users after it" do
      broken = User.create!(email: "broken@example.com", provider: "anthropic",
                            api_keys: { "anthropic" => "sk-ant-test" }, time_zone: "America/Los_Angeles")
      stub_enqueue_for(broken) { raise "unexpected" }
      allow(Rails.logger).to receive(:error)

      travel_to(Time.utc(2026, 7, 13, 15, 0)) do
        expect { described_class.new.perform }.to scheduled_job_for(pac).once
      end
      expect(Rails.logger).to have_received(:error).with("Generation batch skipped user #{broken.id}: RuntimeError: unexpected")
    end

    it "carries on quietly when Solid Queue discards one user's job, which makes perform_later return false" do
      refused = User.create!(email: "busy@example.com", provider: "anthropic",
                             api_keys: { "anthropic" => "sk-ant-test" }, time_zone: "America/Los_Angeles")
      stub_enqueue_for(refused) { false }
      expect(Rails.logger).not_to receive(:error)

      travel_to(Time.utc(2026, 7, 13, 15, 0)) do
        expect { described_class.new.perform }.to scheduled_job_for(pac).once
      end
    end

    it "enqueues one scheduled job for a due user and calls no provider itself" do
      service = stub_provider(pac)

      travel_to(Time.utc(2026, 7, 13, 15, 0)) do
        expect { described_class.new.perform }.to scheduled_job_for(pac).once
      end
      expect(service).not_to have_received(:generate_judged_exercise)
      expect(DailyExercise.where(user: pac).count).to eq(0)
    end

    it "enqueues the scheduled job on the provider queue, behind any job a person is waiting on" do
      travel_to(Time.utc(2026, 7, 13, 15, 0)) do
        expect { described_class.new.perform }
          .to scheduled_job_for(pac).on_queue("provider_calls").at_priority(JobPriority::SCHEDULED)
      end
      expect(JobPriority::SCHEDULED).to be > (GenerateDailyExercisesJob.new(user_id: pac.id).priority || 0)
    end

    it "enqueues a scheduled job for a user whose dashboard generation is running, which the claim then stops" do
      pac.claim_generating!

      travel_to(Time.utc(2026, 7, 13, 15, 0)) do
        expect { described_class.new.perform }.to scheduled_job_for(pac).once
      end
    end

    it "enqueues nothing before 8am local or on a local weekend" do
      [ Time.utc(2026, 7, 13, 14, 0), Time.utc(2026, 7, 18, 17, 0) ].each do |moment|
        travel_to(moment) { expect { described_class.new.perform }.not_to have_enqueued_job(GenerateDailyExercisesJob) }
      end
    end

    it "gates each user by their own zone within one run" do
      alaska = User.create!(email: "alaska@example.com", provider: "anthropic", api_keys: { "anthropic" => "sk-ant-test" }, time_zone: "America/Anchorage")

      travel_to(Time.utc(2026, 7, 13, 15, 0)) do
        expect { described_class.new.perform }.to scheduled_job_for(pac).once
        expect(GenerateDailyExercisesJob).not_to have_been_enqueued.with(user_id: alaska.id, scheduled: true)
      end
    end

    it "enqueues nothing for a paused user, an anonymized user or a user with no key" do
      pac.update!(paused_generation_at: Time.current)
      User.create!(email: "gone@example.com", provider: "anthropic", api_keys: { "anthropic" => "sk-ant-test" }, time_zone: "UTC").anonymize!
      User.create!(email: "keyless@example.com", time_zone: "UTC")

      travel_to(Time.utc(2026, 7, 13, 15, 0)) do
        expect { described_class.new.perform }.not_to have_enqueued_job(GenerateDailyExercisesJob)
      end
    end

    it "enqueues nothing for a user who has today's set, and still checks whether a nudge is due" do
      pac.update!(reminder_level: :ready_and_nudges)

      travel_to(Time.utc(2026, 7, 13, 21, 0)) do
        Time.use_zone(pac.effective_time_zone) do
          DailyExercise.create!(user: pac, date: Date.current, generated_at: Time.current, language: "ruby_rails",
                                problem_set: { "code_review" => { "question" => "q" } })
        end

        expect { described_class.new.perform }
          .to have_enqueued_job(SendPushReminderJob).with(user_id: pac.id, kind: :nudge)
          .and have_enqueued_job(GenerateDailyExercisesJob).exactly(0).times
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
