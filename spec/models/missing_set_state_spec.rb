require "rails_helper"

RSpec.describe MissingSetState do
  let(:quiet_weekday) do
    { trial_ended: false, provider_ready: true, manual_trigger: false, failed_today: false, weekend: false, paused: false }
  end

  def state(**overrides) = described_class.for(**quiet_weekday, **overrides)

  it "starts generating on a weekday with nothing else to say" do
    expect(state).to eq(:start_generation)
  end

  it "names an ended trial ahead of every other state" do
    expect(state(trial_ended: true, provider_ready: false, manual_trigger: true, failed_today: true, weekend: true, paused: true))
      .to eq(:trial_ended)
  end

  it "waits for a provider before anything that would call one" do
    expect(state(provider_ready: false, manual_trigger: true, failed_today: true, weekend: true, paused: true))
      .to eq(:awaiting_provider)
  end

  it "shows a fresh manual trigger as generating, even after a failure earlier today" do
    expect(state(manual_trigger: true, failed_today: true, weekend: true, paused: true)).to eq(:generating)
  end

  it "shows today's failure ahead of the weekend and the pause" do
    expect(state(failed_today: true, weekend: true, paused: true)).to eq(:generation_failed)
  end

  it "names the weekend ahead of the pause, since a weekend is empty either way" do
    expect(state(weekend: true, paused: true)).to eq(:weekend)
  end

  it "names the pause on a weekday" do
    expect(state(paused: true)).to eq(:paused)
  end

  it "takes values only, so it reads no user, trial or clock" do
    expect(described_class.method(:for).parameters.map(&:first)).to all(eq(:keyreq))
  end
end
