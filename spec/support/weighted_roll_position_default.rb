# B so the default path exercises the swap; the file name sorts after roll_defaults.rb on purpose.
RSpec.configure do |config|
  config.before do
    allow(WeightedRoll).to receive(:pick)
      .with(ExerciseSection::DesignComparison::POSITION_WEIGHTS).and_return("b")
  end
end
