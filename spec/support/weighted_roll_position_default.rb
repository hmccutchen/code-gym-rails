# Every example starts with the design comparison's better piece shown as B.
#
# ProblemSetIngest rolls which piece is A on every generation, so without a
# pin every example that renders or asserts on a delivered design comparison
# would change with the roll, page snapshots included. B rather than A so the
# default path exercises the swap from the provider's better_piece/other_piece
# order. A spec about the roll itself stubs it with its own weights, the way
# real_source_default.rb describes, and a later stub wins.
#
# The file name sorts after real_source_default.rb on purpose: its catch-all
# and_call_original, defined later, would otherwise win over this pin.
RSpec.configure do |config|
  config.before do
    allow(WeightedRoll).to receive(:pick)
      .with(ExerciseSection::DesignComparison::POSITION_WEIGHTS).and_return("b")
  end
end
