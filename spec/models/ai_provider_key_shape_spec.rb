require "rails_helper"

RSpec.describe AiProvider, ".detect and the shape of a pasted key" do
  VALID = { "sk-ant-api03-Ab8RN6J5yPUsY9SwLxAS2DYq_cYQ-FIhR9" => "anthropic", "AIzaSyExampleKey12345" => "gemini",
            "AQ.Ab8RN6J5yPUsY9SwLxAS2DYq_cYQFIhR9xG8C0Dz3D9CdyL-qg" => "gemini",
            "sk-proj-Ab8RN6J5yPUsY9SwLxAS2DYq" => "openai" }.freeze

  VALID.each do |key, provider|
    it "detects #{provider} from #{key.first(8)}…" do
      expect(described_class.detect(key)).to eq(provider)
    end
  end

  { "a newline" => "sk-ant-abc\nX-Evil: 1", "a carriage return" => "sk-ant-abc\rdef", "a tab" => "sk-ant-abc\tdef",
    "a space" => "sk-ant-abc def", "a NUL" => "sk-ant-abc\u0000def", "a DEL" => "sk-ant-abc\u007Fdef",
    "a character outside ASCII" => "sk-ant-abcédef", "a trailing newline" => "sk-ant-abcdef\n" }.each do |name, key|
    it "recognizes no provider in a key holding #{name}" do
      expect(described_class.detect(key)).to be_nil
    end
  end

  it "recognizes no provider in a key over the length limit, and still one at it" do
    prefix = "sk-ant-"

    expect(described_class.detect(prefix + ("a" * (described_class::MAX_KEY_LENGTH - prefix.length)))).to eq("anthropic")
    expect(described_class.detect(prefix + ("a" * (described_class::MAX_KEY_LENGTH - prefix.length + 1)))).to be_nil
  end

  it "sets the limit well above the longest key a provider issues today" do
    expect(described_class::MAX_KEY_LENGTH).to be >= 2 * 200
  end

  it "recognizes no provider in nil or an empty key" do
    expect(described_class.detect(nil)).to be_nil
    expect(described_class.detect("")).to be_nil
  end
end
