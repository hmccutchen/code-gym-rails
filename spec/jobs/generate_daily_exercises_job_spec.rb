require "rails_helper"

RSpec.describe GenerateDailyExercisesJob do
  include ActiveSupport::Testing::TimeHelpers

  let(:user) { User.create!(email: "cronuser@example.com", name: "Cron", provider: "anthropic", api_key: "sk-ant-test", time_zone: "UTC") }

  it "creates a DailyExercise from the provider's generated problem set" do
    fake_service = instance_double(ClaudeService, generate_exercise: { "code_review" => {} })
    allow(AiService).to receive(:for).with(user).and_return(fake_service)

    described_class.new.perform(user_id: user.id)

    exercise = DailyExercise.find_by(user: user, date: Date.current)
    expect(exercise.problem_set).to eq("code_review" => {})
  end

  it "does not touch last_generation_error fields on success" do
    fake_service = instance_double(ClaudeService, generate_exercise: { "code_review" => {} })
    allow(AiService).to receive(:for).with(user).and_return(fake_service)

    described_class.new.perform(user_id: user.id)

    expect(user.reload.last_generation_error_date).to be_nil
    expect(user.last_generation_error).to be_nil
  end

  it "logs and continues when AiService::Error is raised" do
    fake_service = instance_double(ClaudeService)
    allow(fake_service).to receive(:generate_exercise).and_raise(AiService::Error, "boom")
    allow(AiService).to receive(:for).with(user).and_return(fake_service)

    expect(Rails.logger).to receive(:error).with(/Failed to generate exercise.*boom/)
    expect { described_class.new.perform(user_id: user.id) }.not_to raise_error
    expect(DailyExercise.exists?(user: user, date: Date.current)).to be false
  end

  it "persists a Settings-pointing error when AiService::AuthenticationError is raised" do
    fake_service = instance_double(ClaudeService)
    allow(fake_service).to receive(:generate_exercise).and_raise(AiService::AuthenticationError, "invalid x-api-key")
    allow(AiService).to receive(:for).with(user).and_return(fake_service)

    expect(Rails.logger).to receive(:error).with(/Auth failure generating exercise.*invalid x-api-key/)
    described_class.new.perform(user_id: user.id)

    user.reload
    expect(user.last_generation_error_date).to eq(Date.current)
    expect(user.last_generation_error).to eq("Your API key was rejected — check it in Settings.")
  end

  it "persists a try-again error when AiService::RateLimitError is raised" do
    fake_service = instance_double(ClaudeService)
    allow(fake_service).to receive(:generate_exercise).and_raise(AiService::RateLimitError, "rate limited")
    allow(AiService).to receive(:for).with(user).and_return(fake_service)

    expect(Rails.logger).to receive(:warn).with(/Rate limited generating exercise.*rate limited/)
    described_class.new.perform(user_id: user.id)

    user.reload
    expect(user.last_generation_error_date).to eq(Date.current)
    expect(user.last_generation_error).to eq("The AI provider is rate-limiting requests — try again shortly.")
  end

  it "persists the raw message when a generic AiService::Error is raised" do
    fake_service = instance_double(ClaudeService)
    allow(fake_service).to receive(:generate_exercise).and_raise(AiService::Error, "boom")
    allow(AiService).to receive(:for).with(user).and_return(fake_service)
    allow(Rails.logger).to receive(:error)

    described_class.new.perform(user_id: user.id)

    user.reload
    expect(user.last_generation_error_date).to eq(Date.current)
    expect(user.last_generation_error).to eq("boom")
  end

  it "persists the failure date in the user's own time zone" do
    pac = User.create!(email: "pac2@example.com", name: "Pac", provider: "anthropic",
                       api_key: "sk-ant-test", time_zone: "America/Los_Angeles")
    fake_service = instance_double(ClaudeService)
    allow(fake_service).to receive(:generate_exercise).and_raise(AiService::Error, "boom")
    allow(AiService).to receive(:for).with(pac).and_return(fake_service)
    allow(Rails.logger).to receive(:error)

    # 2026-07-13 06:00 UTC == 2026-07-12 23:00 PDT — still July 12th in LA.
    travel_to(Time.utc(2026, 7, 13, 6, 0)) do
      described_class.new.perform(user_id: pac.id)
    end

    expect(pac.reload.last_generation_error_date).to eq(Date.new(2026, 7, 12))
  end

  it "persists the resolved language on the created DailyExercise" do
    user.update!(language: "javascript")
    fake_service = instance_double(ClaudeService, generate_exercise: { "code_review" => {} })
    allow(AiService).to receive(:for).with(user).and_return(fake_service)

    described_class.new.perform(user_id: user.id)

    exercise = DailyExercise.find_by(user: user, date: Date.current)
    expect(exercise.language).to eq("javascript")
  end

  it "passes the resolved language through to generate_exercise" do
    user.update!(language: "javascript")
    fake_service = instance_double(ClaudeService, generate_exercise: { "code_review" => {} })
    allow(AiService).to receive(:for).with(user).and_return(fake_service)

    described_class.new.perform(user_id: user.id)

    expect(fake_service).to have_received(:generate_exercise).with(user, language: "javascript")
  end

  it "logs and continues when a concurrent job already created today's exercise (unique index race)" do
    fake_service = instance_double(ClaudeService, generate_exercise: { "code_review" => {} })
    allow(AiService).to receive(:for).with(user).and_return(fake_service)
    allow(DailyExercise).to receive(:create!).and_raise(
      ActiveRecord::RecordNotUnique.new("duplicate key value violates unique constraint")
    )

    expect(Rails.logger).to receive(:info).with(/Skipped duplicate generation/)
    expect { described_class.new.perform(user_id: user.id) }.not_to raise_error
    expect(user.reload.last_generation_error_date).to be_nil
  end

  it "skips an anonymized user on the on-demand path" do
    user.anonymize!
    expect(AiService).not_to receive(:for)

    described_class.new.perform(user_id: user.id)

    expect(DailyExercise.exists?(user: user, date: Date.current)).to be false
  end

  describe "hourly batch (no user_id), zone-gated" do
    def stub_generation_for(u)
      svc = instance_double(ClaudeService, generate_exercise: { "code_review" => {} })
      allow(AiService).to receive(:for).with(u).and_return(svc)
    end

    let(:pac) { User.create!(email: "pac@example.com", name: "Pac", provider: "anthropic", api_key: "sk-ant-test", time_zone: "America/Los_Angeles") }

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
      alaska = User.create!(email: "alaska@example.com", name: "Alaska", provider: "anthropic",
                             api_key: "sk-ant-test", time_zone: "America/Anchorage")
      stub_generation_for(pac)
      stub_generation_for(alaska)

      travel_to(Time.utc(2026, 7, 13, 15, 0)) do
        described_class.new.perform

        pac_local_today = Time.use_zone("America/Los_Angeles") { Date.current }
        expect(DailyExercise.exists?(user: pac, date: pac_local_today)).to be true

        expect(DailyExercise.where(user: alaska).count).to eq(0)
      end
    end
  end
end
