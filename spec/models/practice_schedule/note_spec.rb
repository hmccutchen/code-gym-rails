require "rails_helper"

RSpec.describe PracticeSchedule::Note do
  let(:note) do
    { "version" => 2, "policy" => 2, "sequence" => 4, "initial_ready" => true,
      "regular_kinds" => %w[code_review design_comparison], "selected_kinds" => %w[pattern],
      "assignments" => {}, "continuation" => { "kind_service" => { "pattern" => 4 }, "service" => {} } }
  end

  it "reads the single-slot continuation without legacy turn fields" do
    expect(described_class.decode(note)).to eq(note)
    expect(described_class.decode(note)).not_to equal(note)
  end

  it "retains registered kinds outside current preferences in committed service" do
    note["continuation"]["kind_service"]["architecture"] = 1
    expect(described_class.decode(note)).to eq(note)
  end

  it "rejects unknown fields, kinds and impossible service sequences" do
    changes = [ { "phase" => nil }, { "version" => 2.0 }, { "selected_kinds" => [] },
      { "continuation" => { "kind_service" => { "unknown" => 1 }, "service" => {} } },
      { "continuation" => { "kind_service" => { "pattern" => 5 }, "service" => {} } },
      { "continuation" => { "kind_service" => { "pattern" => -1 }, "service" => {} } },
      { "continuation" => { "kind_service" => { "pattern" => 1.0 }, "service" => {} } } ]
    changes.each do |change|
      expect { described_class.decode(note.merge(change)) }.to raise_error(ArgumentError)
    end
  end

  it "preserves strict assignment and service identity validation" do
    note["assignments"] = { "pattern" => { "concept" => "sync_vs_async", "bucket" => "architecture",
      "reason" => "retention", "adjustment" => "normal" } }
    expect { described_class.decode(note) }.to raise_error(ArgumentError)
  end
end
