require "rails_helper"

RSpec.describe TrialMode do
  it "offers a provider with a data notice and a house key, and none under the kill switch" do
    expect(described_class.providers).to eq([])

    stub_env("HOUSE_OPENAI_API_KEY" => "sk-house", "HOUSE_GEMINI_API_KEY" => "AIza-house",
             "HOUSE_ANTHROPIC_API_KEY" => "sk-ant-house", "HOUSE_FAKE_API_KEY" => "fake-house")
    expect(described_class.providers).to match_array(%w[anthropic gemini openai fake])

    stub_env("TRIALS_DISABLED" => "1")
    expect(described_class.providers).to eq([])
  end

  it "offers no provider whose data notice is missing" do
    stub_env("HOUSE_OPENAI_API_KEY" => "sk-house")
    allow(I18n).to receive(:exists?).and_call_original
    allow(I18n).to receive(:exists?).with("trials.data_notice.openai").and_return(false)

    expect(described_class.providers).to eq([])
  end
end
