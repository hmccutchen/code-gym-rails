require "rails_helper"

RSpec.describe PracticeAdjustment do
  let(:kind) { ExerciseSection::Pattern }
  let(:rungs) { { kind.key => "senior" } }
  let(:assignment) { { concept: "memoization", bucket: "ruby_rails", mode: "normal_retry", source_response_id: 1 } }

  def resolve(mode:, locked: false, reduced: true)
    difficulty = KindDifficulty.new(levels: locked ? { kind.key => "senior" } : {}, locked: locked ? [ kind.key ] : [])
    described_class.resolve(assignments: { kind.key => assignment.merge(mode: mode) }, difficulty: difficulty,
      rungs: rungs, reduced: reduced ? { kind.key => [ "memoization" ] } : {}).fetch(kind.key)
  end

  it "keeps a normal retry and support at the chosen demand despite a reduced fallback" do
    %w[normal_retry support].each do |mode|
      expect(resolve(mode: mode)).to include(mode: mode, eased: false)
    end
    expect(resolve(mode: "simplified")).to include(mode: "simplified", eased: true)
  end

  it "suppresses easing and rating help under a lock without clearing concept intent" do
    %w[normal_retry support simplified].each do |mode|
      expect(resolve(mode: mode, locked: true)).to include(concept: "memoization", mode: "normal",
        eased: false, lock_suppressed: true)
    end
  end
end
