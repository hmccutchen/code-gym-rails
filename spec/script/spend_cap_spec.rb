require "rails_helper"
require Rails.root.join("script/spend_cap")

RSpec.describe SpendCap do
  let(:out) { StringIO.new }
  let(:cap) { described_class.new(1.0, out) }

  it "lets a call through while the spent amount and that call's bound stay within the limit" do
    cap.record(0.40, "retry_section")

    expect { cap.check!(0.60) }.not_to raise_error
  end

  it "stops before a call whose bound could take spending past the limit, saying what it stopped on" do
    cap.record(0.40, "retry_section")

    expect { cap.check!(0.61) }.to raise_error(described_class::Reached, /\$0\.61.*\$0\.40 spent of the \$1\.00 cap/)
  end

  it "prints the running total after each call" do
    cap.record(0.25, "retry_section")
    cap.record(0.10, "judge_section")

    expect(out.string.lines.map(&:strip)).to eq([ "$0.25 spent of $1.00 (retry_section)", "$0.35 spent of $1.00 (judge_section)" ])
  end

  it "refuses a limit that isn't a positive amount" do
    [ 0, -1, nil ].each { |limit| expect { described_class.new(limit, out) }.to raise_error(ArgumentError, /positive/) }
  end
end
