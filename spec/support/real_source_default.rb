# Every example starts with the real-source sub-roll pinned to :toy.
#
# DailyPlan already rolls the code_review mode at random and the suite
# tolerates that, because the mode only changes the prompt — a canned
# provider response comes back through ingest identical either way. The
# real-source roll is different: when it lands, ProblemSetIngest stamps a
# scenario and a source id onto the set, so every example that asserts on
# what a generation DELIVERED became nondeterministic at 35% the day the
# roll existed. Pinning here keeps those examples testing the toy path they
# were written against, in one place rather than one pin per example.
#
# An example that exercises the grounded path overrides this with its own
# `allow(WeightedRoll).to receive(:pick).with(RealSource::WEIGHTS).and_return(:real)`
# — a later stub wins — so the feature stays tested where it is meant to be,
# never by accident elsewhere.
RSpec.configure do |config|
  config.before do
    allow(WeightedRoll).to receive(:pick).and_call_original
    allow(WeightedRoll).to receive(:pick).with(RealSource::WEIGHTS).and_return(:toy)
  end
end
