require "rails_helper"

RSpec.describe GenerateRecognitionGuideJob do
  let(:user) { User.create!(email: "guide-job@example.com", name: "Job", api_key: "sk-ant-test", provider: "anthropic") }

  def stub_service
    service = instance_double(ClaudeService)
    allow(service).to receive(:generate_recognition_guide)
      .with(user, "code_smell").and_return(FakeService::RECOGNITION_GUIDE.dup)
    allow(AiService).to receive(:for).with(user).and_return(service)
    service
  end

  it "creates the guide with the generated fields" do
    stub_service

    expect {
      described_class.perform_now(group_key: "code_smell", user_id: user.id)
    }.to change(RecognitionGuide, :count).by(1)

    guide = RecognitionGuide.last
    expect(guide.group_key).to eq("code_smell")
    expect(guide.questions).to eq(FakeService::RECOGNITION_GUIDE["questions"])
  end

  it "never rewrites a guide that exists" do
    RecognitionGuide.create!(group_key: "code_smell", questions: "q", contrast: "c", misfires: "m")
    expect(AiService).not_to receive(:for)

    described_class.perform_now(group_key: "code_smell", user_id: user.id)

    expect(RecognitionGuide.sole.questions).to eq("q")
  end

  it "does nothing for a key outside the recognition groups" do
    expect(AiService).not_to receive(:for)

    expect { described_class.perform_now(group_key: "core", user_id: user.id) }.not_to change(RecognitionGuide, :count)
  end

  it "does nothing when the user no longer exists" do
    expect(AiService).not_to receive(:for)

    described_class.perform_now(group_key: "code_smell", user_id: -1)
  end

  it "swallows a provider error and writes nothing" do
    service = instance_double(ClaudeService)
    allow(service).to receive(:generate_recognition_guide).and_raise(AiService::InvalidResponseError, "missing")
    allow(AiService).to receive(:for).with(user).and_return(service)

    expect { described_class.perform_now(group_key: "code_smell", user_id: user.id) }.not_to change(RecognitionGuide, :count)
  end

  it "swallows a lost race on the unique index" do
    stub_service
    allow(RecognitionGuide).to receive(:create!).and_raise(ActiveRecord::RecordNotUnique, "duplicate key")

    expect { described_class.perform_now(group_key: "code_smell", user_id: user.id) }.not_to raise_error
  end

  it "swallows a lost race caught by the uniqueness validation" do
    stub_service
    invalid = RecognitionGuide.new(group_key: "code_smell")
    invalid.errors.add(:group_key, :taken)
    allow(RecognitionGuide).to receive(:create!).and_raise(ActiveRecord::RecordInvalid, invalid)

    expect { described_class.perform_now(group_key: "code_smell", user_id: user.id) }.not_to raise_error
  end
end
