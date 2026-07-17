require "rails_helper"

RSpec.describe GenerateDailyExercisesJob do
  let(:user) { User.create!(email: "cronuser@example.com", name: "Cron", provider: "anthropic", api_key: "sk-ant-test", time_zone: "UTC") }

  it "creates a DailyExercise from the provider's generated problem set" do
    fake_service = instance_double(ClaudeService, generate_exercise: { "code_review" => {} })
    allow(AiService).to receive(:for).with(user).and_return(fake_service)
    allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)

    described_class.new.perform(user_id: user.id)

    exercise = DailyExercise.find_by(user: user, date: Date.current)
    expect(exercise.problem_set).to eq("code_review" => {})
  end

  it "logs and continues when AiService::Error is raised" do
    fake_service = instance_double(ClaudeService)
    allow(fake_service).to receive(:generate_exercise).and_raise(AiService::Error, "boom")
    allow(AiService).to receive(:for).with(user).and_return(fake_service)

    expect(Rails.logger).to receive(:error).with(/Failed to generate exercise.*boom/)
    expect { described_class.new.perform(user_id: user.id) }.not_to raise_error
    expect(DailyExercise.exists?(user: user, date: Date.current)).to be false
  end

  it "persists the resolved language on the created DailyExercise" do
    user.update!(language: "javascript")
    fake_service = instance_double(ClaudeService, generate_exercise: { "code_review" => {} })
    allow(AiService).to receive(:for).with(user).and_return(fake_service)
    allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)

    described_class.new.perform(user_id: user.id)

    exercise = DailyExercise.find_by(user: user, date: Date.current)
    expect(exercise.language).to eq("javascript")
  end

  it "passes the resolved language through to generate_exercise" do
    user.update!(language: "javascript")
    fake_service = instance_double(ClaudeService, generate_exercise: { "code_review" => {} })
    allow(AiService).to receive(:for).with(user).and_return(fake_service)
    allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)

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
  end

  it "broadcasts the rendered exercise partial to the user's stream on success" do
    fake_service = instance_double(ClaudeService, generate_exercise: { "code_review" => {} })
    allow(AiService).to receive(:for).with(user).and_return(fake_service)

    expect(Turbo::StreamsChannel).to receive(:broadcast_replace_to) do |streamable, target:, partial:, locals:|
      expect(streamable).to eq(user)
      expect(target).to eq("dashboard-content")
      expect(partial).to eq("dashboard/exercise")
      expect(locals[:exercise]).to be_a(DailyExercise)
      expect(locals[:exercise].user).to eq(user)
      expect(locals[:response]).to be_a(DailyResponse)
      expect(locals[:response]).not_to be_persisted
    end

    described_class.new.perform(user_id: user.id)
  end

  it "broadcasts a friendly failure partial to the user's stream when AiService::Error is raised" do
    fake_service = instance_double(ClaudeService)
    allow(fake_service).to receive(:generate_exercise).and_raise(AiService::Error, "boom")
    allow(AiService).to receive(:for).with(user).and_return(fake_service)
    allow(Rails.logger).to receive(:error)

    expect(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
      .with(user, target: "dashboard-content", partial: "dashboard/generation_failed", locals: { message: "boom" })

    described_class.new.perform(user_id: user.id)
  end

  describe "hourly batch (no user_id), zone-gated" do
    include ActiveSupport::Testing::TimeHelpers

    def stub_generation_for(u)
      svc = instance_double(ClaudeService, generate_exercise: { "code_review" => {} })
      allow(AiService).to receive(:for).with(u).and_return(svc)
      allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
    end

    let(:pac) { User.create!(email: "pac@example.com", name: "Pac", provider: "anthropic", api_key: "sk-ant-test", time_zone: "America/Los_Angeles") }

    it "does not generate before 8am local" do
      stub_generation_for(pac)
      # 2026-07-13 14:00 UTC == 07:00 PDT (Monday, before 8am local)
      travel_to(Time.utc(2026, 7, 13, 14, 0)) do
        described_class.new.perform
        local_today = Time.use_zone("America/Los_Angeles") { Date.current }
        expect(DailyExercise.exists?(user: pac, date: local_today)).to be false
      end
    end

    it "generates at/after 8am local on a weekday" do
      stub_generation_for(pac)
      # 2026-07-13 15:00 UTC == 08:00 PDT (Monday, at 8am local)
      travel_to(Time.utc(2026, 7, 13, 15, 0)) do
        described_class.new.perform
        local_today = Time.use_zone("America/Los_Angeles") { Date.current }
        expect(DailyExercise.exists?(user: pac, date: local_today)).to be true
      end
    end

    it "does not generate on a local weekend" do
      stub_generation_for(pac)
      # 2026-07-18 17:00 UTC == 10:00 PDT Saturday
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
      # 2026-07-13 15:00 UTC == 08:00 PDT Monday (at 8am local, generated)
      #                      == 07:00 AKDT Monday (before 8am local, not generated)
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
