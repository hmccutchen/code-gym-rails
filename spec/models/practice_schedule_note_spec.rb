require "rails_helper"

RSpec.describe PracticeSchedule::Note do
  include AuthHelpers
  let(:note) do
    {
      "version" => 2, "policy" => 2, "selection_policy" => "single_slot", "sequence" => 3,
      "initial_ready" => true, "regular_kinds" => %w[code_review design_comparison],
      "phase" => nil, "selected_kinds" => %w[code_review], "assignments" => {},
      "continuation" => {
        "next_phase" => 0, "kind_order" => %w[code_review architecture], "next_kind_index" => 1,
        "last_omitted_kind" => nil, "service" => {}
      }
    }
  end

  it "reads a single-slot schedule without changing its mastery policy or continuation" do
    decoded = described_class.decode(note)
    expect(decoded).to eq(note)
    decoded["continuation"]["kind_order"].clear
    expect(note["continuation"]["kind_order"]).to eq(%w[code_review architecture])
  end

  it "reads a stored version-two note through enrollment and the next schedule context" do
    user = create_user_with_key
    exercise = user.daily_exercises.create!(date: Date.current, generated_at: Time.current,
      problem_set: { "code_review" => { "question" => "Review the code." } },
      plan_notes: { "practice_schedule" => note })

    expect(exercise.reload.practice_schedule).to eq(note)
    expect(PracticeSchedule.context_for(user)).to eq(note)
    user.with_lock { expect(PracticePolicyMode.active?(user, initiate: false)).to be(true) }
    expect(exercise.reload.plan_notes["practice_schedule"]).to eq(note)
  end

  it "rejects an unknown selection policy and legacy turn markers" do
    [ { "selection_policy" => "unknown" }, { "phase" => 0 },
      { "omitted_kind" => "design_comparison" }, { "version" => 3 } ].each do |change|
      expect { described_class.decode(note.merge(change)) }.to raise_error(ArgumentError)
    end
    expect { described_class.decode(note.except("selection_policy")) }.to raise_error(ArgumentError)
  end

  it "retains strict kind, assignment and service validation" do
    bad_assignment = { "concept" => "sync_vs_async", "bucket" => "architecture", "reason" => "support", "adjustment" => "support" }
    changes = [
      { "selected_kinds" => %w[code_review code_review] },
      { "assignments" => { "code_review" => bad_assignment } },
      { "continuation" => note["continuation"].merge("kind_order" => %w[invented]) },
      { "continuation" => note["continuation"].merge("next_kind_index" => 2) }
    ]
    changes.each do |change|
      expect { described_class.decode(note.merge(change)) }.to raise_error(ArgumentError)
    end
  end

  it "keeps version-one schedules exact and rejects the new field on them" do
    legacy = note.except("selection_policy").merge("version" => 1)
    legacy["continuation"] = legacy["continuation"].merge("kind_order" => %w[architecture], "next_kind_index" => 0)
    expect(described_class.decode(legacy)).to eq(legacy)
    expect { described_class.decode(legacy.merge("selection_policy" => "single_slot")) }.to raise_error(ArgumentError)
  end
end
