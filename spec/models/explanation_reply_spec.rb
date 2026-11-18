require "rails_helper"

RSpec.describe ExplanationReply do
  def parse(raw) = described_class.parse(raw)

  it "reads a sound line and a correction" do
    reply = parse("sound" => "You named the per-row query.", "correction" => "Preloading runs one extra query, not none.")

    expect(reply).to have_attributes(sound: "You named the per-row query.", correction: "Preloading runs one extra query, not none.")
    expect(reply.to_h).to eq("sound" => "You named the per-row query.", "correction" => "Preloading runs one extra query, not none.")
  end

  it "reads a correct explanation's reply, with a null correction" do
    expect(parse("sound" => "That is right.", "correction" => nil).correction).to be_nil
  end

  it "trims each line" do
    expect(parse("sound" => "  That is right. ", "correction" => nil).sound).to eq("That is right.")
  end

  it "counts anything else as a failed call" do
    [
      nil, [], "text", {},
      { "sound" => "", "correction" => nil },
      { "sound" => "Two\nlines.", "correction" => nil },
      { "sound" => "x" * (described_class::MAX_LENGTH + 1), "correction" => nil },
      { "sound" => "Fine.", "correction" => "y" * (described_class::MAX_LENGTH + 1) },
      { "sound" => "Fine.", "correction" => "Two\nlines." },
      { "sound" => "Fine.", "correction" => "" },
      { "sound" => "Fine.", "correction" => 3 },
      { "sound" => "Fine." }
    ].each do |raw|
      expect { parse(raw) }.to raise_error(ProviderError::InvalidResponseError), raw.inspect
    end
  end

  it "reads a stored reply back, and nothing from a value that is not one" do
    expect(described_class.from_stored("sound" => "Right.", "correction" => nil)).to have_attributes(sound: "Right.", correction: nil)
    expect(described_class.from_stored(nil)).to be_nil
    expect(described_class.from_stored("sound" => 4)).to be_nil
  end
end
