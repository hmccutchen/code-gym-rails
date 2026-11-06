require "rails_helper"

RSpec.describe "Mastery application receipt" do
  [ nil, [], "text", false, 0, { "version" => 2 }, { "version" => 1 } ].each do |bad|
    it "refuses #{bad.inspect}, including values PostgreSQL NOT NULL permits" do
      expect { DailyResponse.decode_mastery_application(bad) }.to raise_error(ArgumentError)
    end
  end

  it "accepts only the empty object as unused and returns independent closed receipts" do
    expect(DailyResponse.decode_mastery_application({})).to eq({})
    receipt = { "version" => 1, "legacy_sections" => [], "processed_sections" => %w[pattern],
      "session_counted" => true, "skip_attempts" => [ [ "ruby_rails", "memoization" ] ] }
    decoded = DailyResponse.decode_mastery_application(receipt)
    expect(decoded).to eq(receipt)
    decoded["processed_sections"] << "challenge"
    expect(receipt["processed_sections"]).to eq(%w[pattern])
    expect { DailyResponse.decode_mastery_application(receipt.merge("extra" => false)) }.to raise_error(ArgumentError)
  end
end
