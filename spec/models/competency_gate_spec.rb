require "rails_helper"

RSpec.describe CompetencyGate do
  let(:start) { Date.new(2026, 1, 1) }

  def result(n, kind: "pattern", grade: "solid", rating: "right_level", eased: false, rung: "junior")
    ReviewedSectionResults::Result.new(date: start + n, kind: kind, level: rung,
      ai_rating: grade, self_rating: rating, eased: eased)
  end

  def day(n, results: [ result(n) ], state: :complete, assigned: 2, delivered: assigned, answered: delivered,
          hard: [], known: true, rungs: {})
    described_class::Day.new(date: start + n, results: results, rungs: rungs,
      completion: described_class::Completion.new(state: state, assigned: assigned, delivered: delivered,
        answered: answered, too_hard: hard, ratings_known: known))
  end

  def grown
    described_class.new.tap { |gate| 5.times { |n| gate.add(day(n)) } }
  end

  it "feeds its previous count into delivery through growth, skips and recovery" do
    gate = described_class.new
    assignments, counts = [], []
    11.times do |n|
      assigned = gate.plan.count
      assignments << assigned
      skipping = [ 7, 8 ].include?(n)
      gate.add(day(n, assigned: assigned, delivered: assigned, answered: assigned - (skipping ? 1 : 0),
        state: skipping ? :incomplete : :complete, results: [ result(n), result(n, kind: "challenge") ]))
      counts << gate.plan.count
    end
    expect(assignments).to eq([ 2 ] + counts[0...-1])
    expect(counts).to eq([ 2, 2, 2, 2, 3, 3, 4, 4, 3, 3, 4 ])
  end

  it "needs five separate attempts with four good grades, not pooled successes" do
    gate = described_class.new
    4.times { |n| gate.add(day(n, results: [ result(n), result(n, kind: "challenge") ])) }
    expect(gate.plan.count).to eq(2)
    gate.add(day(4, results: [ result(4, grade: "developing") ]))
    expect(gate.plan.count).to eq(3)
  end

  it "keeps poor grades at two even when every full set is complete" do
    expect(described_class.plan(10.times.map { |n| day(n, results: [ result(n, grade: "developing") ]) }).count).to eq(2)
  end

  it "requires two independent kinds and two new full three-core sets for four" do
    gate = described_class.new
    5.times { |n| gate.add(day(n, results: [ result(n), result(n, kind: "challenge", rung: "senior") ])) }
    expect(gate.plan.count).to eq(3)
    gate.add(day(5, assigned: 3))
    expect(gate.plan.count).to eq(3)
    gate.add(day(6, assigned: 3))
    expect(gate.plan.count).to eq(4)
  end

  it "does not let one qualifying kind reach four" do
    gate = grown
    5.times { |n| gate.add(day(n + 5, assigned: 3)) }
    expect(gate.plan.count).to eq(3)
  end

  it "lets a strict partial finish grade proof against already earned capacity" do
    gate = described_class.new
    4.times { |n| gate.add(day(n)) }
    gate.add(day(4, state: :unknown))
    expect(gate.plan.count).to eq(3)
  end

  it "resets hard effort on a rung change without resurrecting it on return" do
    gate = grown
    2.times { |n| gate.add(day(n + 5, state: :unknown, results: [ result(n + 5, rating: "too_hard", eased: true) ])) }
    expect(gate.plan.evidence[:kinds]["pattern"][:effort_blocked]).to be(true)
    gate.add(day(7, state: :unknown, results: [ result(7, rung: "senior") ]))
    expect(gate.plan.evidence[:kinds]["pattern"]).to include(successes: 1, effort_blocked: false)
    gate.add(day(8, state: :unknown))
    expect(gate.plan.evidence[:kinds]["pattern"]).to include(successes: 1, effort_blocked: false)
    expect(gate.plan.count).to eq(3)
  end

  it "retains normal grades through eased hardship and clears effort only with normal comfort" do
    gate = described_class.new
    5.times { |n| gate.add(day(n, results: [ result(n), result(n, kind: "challenge") ])) }
    2.times { |n| gate.add(day(n + 5, results: [ result(n + 5, rating: "too_hard", eased: true) ], state: :unknown)) }
    5.times { |n| gate.add(day(n + 7, results: [ result(n + 7, eased: true) ], assigned: 3)) }
    expect(gate.plan.count).to eq(3)
    expect(gate.plan.evidence[:kinds]["pattern"]).to include(successes: 5, effort_blocked: true)
    3.times { |n| gate.add(day(n + 12, results: [ result(n + 12, rating: nil) ], state: :unknown)) }
    expect(gate.plan.count).to eq(3)
    gate.add(day(15))
    expect(gate.plan.count).to eq(3)
    gate.add(day(16))
    expect(gate.plan.count).to eq(4)
  end

  it "allows one hard rating but another kind can qualify despite two" do
    days = 5.times.map do |n|
      day(n, results: [ result(n, rating: n >= 3 ? "too_hard" : "right_level"),
        result(n, kind: "challenge", rating: n == 4 ? "too_hard" : nil) ])
    end
    plan = described_class.plan(days)
    expect(plan.count).to eq(3)
    expect(plan.evidence[:kinds]["pattern"][:qualified]).to be(false)
    expect(plan.evidence[:kinds]["challenge"][:qualified]).to be(true)
  end

  it "starts both windows afresh only for the changed kind, including an absent kind" do
    gate = grown
    gate.add(day(5, results: [ result(5, kind: "challenge") ], rungs: { "pattern" => "senior" }, assigned: 3))
    expect(gate.plan.count).to eq(3)
    expect(gate.plan.evidence[:kinds]["pattern"]).to include(successes: 0, rung: "senior")
    gate.add(day(6, rungs: { "pattern" => "junior" }, assigned: 3))
    expect(gate.plan.evidence[:kinds]["pattern"][:successes]).to eq(1)
    expect(gate.plan.evidence[:kinds]["challenge"][:successes]).to eq(1)
  end

  it "does not allow an inconsistent section stamp to override server context" do
    gate = grown
    gate.add(day(5, rungs: { "pattern" => "senior" }, assigned: 3))
    expect(gate.plan.evidence[:kinds]["pattern"]).to include(successes: 0, rung: "senior")
    expect(gate.plan.evidence[:capacity][:full_run]).to eq(1)
  end

  it "holds on one actual skip and reduces one on the second, retaining grades" do
    gate = grown
    gate.add(day(5, assigned: 3, state: :incomplete, answered: 2))
    expect(gate.plan).to have_attributes(count: 3, safety_hold: true)
    gate.add(day(6, assigned: 3, state: :incomplete, answered: 2))
    expect(gate.plan).to have_attributes(count: 2, reason: :completion, safety_hold: true)
    expect(gate.plan.evidence[:kinds]["pattern"][:successes]).to eq(5)
    2.times { |n| gate.add(day(n + 7)) }
    expect(gate.plan).to have_attributes(count: 3, safety_hold: false)
  end

  it "makes unknown days inert but short completed days interrupt an actual-skip run" do
    gate = grown
    gate.add(day(5, assigned: 3, state: :incomplete, answered: 1))
    before = gate.plan
    gate.add(day(6, results: [], state: :unknown))
    expect(gate.plan).to eq(before)
    gate.add(day(7, assigned: 3, delivered: 2, results: []))
    gate.add(day(8, assigned: 3, state: :incomplete, answered: 1))
    expect(gate.plan.count).to eq(3)
  end

  it "interrupts legacy skip runs with known full short work without inventing capacity" do
    gate = grown
    gate.add(day(5, assigned: nil, delivered: 2, state: :incomplete, answered: 1))
    gate.add(day(6, assigned: nil, delivered: 2))
    gate.add(day(7, assigned: nil, delivered: 2, state: :incomplete, answered: 1))
    expect(gate.plan.count).to eq(3)
    expect(gate.plan.evidence[:capacity][:full_run]).to eq(0)
  end

  it "reduces four to three and regrows only after two comfortable full three-core sets" do
    gate = described_class.new
    7.times do |n|
      gate.add(day(n, results: [ result(n), result(n, kind: "challenge") ], assigned: n < 5 ? 2 : 3))
    end
    expect(gate.plan.count).to eq(4)
    2.times { |n| gate.add(day(n + 7, assigned: 4, state: :incomplete, answered: 2)) }
    expect(gate.plan.count).to eq(3)
    gate.add(day(9, assigned: 3))
    expect(gate.plan.count).to eq(3)
    gate.add(day(10, assigned: 3))
    expect(gate.plan.count).to eq(4)
  end

  it "does not let one struggling kind trigger broad overload or reduce an earned size" do
    gate = grown
    6.times { |n| gate.add(day(n + 5, assigned: 3, results: [ result(n + 5, rating: "too_hard") ], hard: [ "pattern" ])) }
    expect(gate.plan).to have_attributes(count: 3, safety_hold: false)
  end

  it "accepts complete larger assignments but never gives drop or supplementary credit" do
    full = 5.times.map { |n| day(n, assigned: 3) }
    short = 5.times.map { |n| day(n, assigned: 3, delivered: 2) }
    expect(described_class.plan(full).count).to eq(3)
    expect(described_class.plan(short).count).to eq(2)
  end

  it "does not diagnose smaller-count skips from incomplete larger assignments" do
    gate = grown
    2.times { |n| gate.add(day(n + 5, assigned: 4, state: :incomplete, answered: 2)) }
    expect(gate.plan).to have_attributes(count: 3, safety_hold: false)
  end

  it "reduces for two repeatedly hard kinds within two rated sets and consumes the trigger" do
    gate = grown
    2.times do |n|
      gate.add(day(n + 5, results: [ result(n + 5, rating: "too_hard"), result(n + 5, kind: "challenge", rating: "too_hard") ],
        assigned: 3, hard: %w[pattern challenge]))
    end
    expect(gate.plan).to have_attributes(count: 2, reason: :brake, safety_hold: true)
    expect(gate.plan.evidence[:kinds]["pattern"][:effort_blocked]).to be(true)
    gate.add(day(7, results: [ result(7, rating: "too_hard") ]))
    expect(gate.plan.reason).to eq(:held)
  end

  it "coalesces skip and overload causes into one reduction" do
    gate = grown
    2.times do |n|
      gate.add(day(n + 5, results: [ result(n + 5, rating: "too_hard"), result(n + 5, kind: "challenge", rating: "too_hard") ],
        assigned: 3, state: :incomplete, answered: 2))
    end
    expect(gate.plan.count).to eq(2)
    expect(gate.plan.evidence[:causes]).to eq(%i[brake completion])
  end

  it "requires known comfortable full recovery, allowing one hard kind" do
    gate = grown
    2.times { |n| gate.add(day(n + 5, assigned: 3, state: :incomplete, answered: 1)) }
    gate.add(day(7, known: false))
    expect(gate.plan.safety_hold).to be(true)
    gate.add(day(8, hard: [ "pattern" ]))
    gate.add(day(9, hard: %w[pattern challenge]))
    expect(gate.plan.safety_hold).to be(true)
    gate.add(day(10, hard: [ "pattern" ]))
    gate.add(day(11, hard: [ "pattern" ]))
    expect(gate.plan.count).to eq(3)
  end

  it "consumes triggers at the floor without claiming a smaller count" do
    gate = described_class.new
    2.times { |n| gate.add(day(n, state: :incomplete, answered: 1)) }
    expect(gate.plan).to have_attributes(count: 2, safety_hold: true)
    expect(gate.plan.evidence[:last_transition]).to eq((start + 1).to_s)
  end

  it "rejects duplicate evidence dates and preserves prefixes and empty-day identity" do
    days = 7.times.map { |n| day(n, assigned: n < 5 ? 2 : 3) }
    expect(described_class.plans(days).first(5)).to eq(described_class.plans(days.first(5)))
    gate = grown
    before = gate.plan
    gate.add(day(4, results: [], state: :none))
    expect(gate.plan).to eq(before)
    expect { gate.add(day(4)) }.to raise_error(ArgumentError)
    expect(described_class.plan(days)).to eq(days.inject(described_class.new) { |fold, event| fold.add(event) }.plan)
  end
end
