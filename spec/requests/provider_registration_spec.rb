require "rails_helper"

RSpec.describe "AI provider registration", type: :request do
  include AuthHelpers

  it "lets one registered class supply dispatch, validation and key detection" do
    provider = Class.new(AiService) do
      def self.provider_key = "example"
      def self.key_pattern = /\Aexample-/

      private

      def build_connection = nil
    end
    stub_const("ExampleService", provider)
    allow(AiProvider).to receive(:all).and_return(AiProvider.all + [ provider ])
    user = User.create!(email: "provider-registration@example.com", name: "Provider registration")
    login_as(user)

    patch setup_path, params: { api_key: "example-test-key" }

    expect(response).to redirect_to(root_path)
    expect(user.reload.provider).to eq("example")
    expect(user.api_key).to eq("example-test-key")
    expect(user).to be_valid
    expect(AiService.for(user)).to be_a(provider)
  end

  it "does not expose the test provider through key detection" do
    expect(AiProvider.detect("fake-test-key")).to be_nil
  end

  it "does not allow unknown provider names to resolve arbitrary constants" do
    expect(AiProvider.find("Kernel")).to be_nil
    expect(AiProvider.find(nil)).to be_nil
  end

  it "does not let OpenAI key detection claim Anthropic keys" do
    expect(OpenaiService.key_pattern).not_to match("sk-ant-api03-test-key")
  end
end
