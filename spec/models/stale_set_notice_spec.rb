require "rails_helper"

RSpec.describe StaleSetNotice do
  def key(held_is_shown: false, shown_submitted: false, paused: false, missing_set: :start_generation)
    described_class.out_of_date(held_is_shown: held_is_shown, shown_submitted: shown_submitted,
                                paused: paused, missing_set: missing_set)
  end

  it "says Reload starts today's set on a weekday where it would start generation" do
    expect(key).to eq("dashboard.stale_set.starts_generation")
  end

  it "says Reload shows today's page wherever it starts nothing" do
    %i[weekend generation_failed trial_ended awaiting_provider].each do |state|
      expect(key(missing_set: state)).to eq("dashboard.stale_set.shows_today"), state.inspect
    end
  end

  it "says Reload brings the same set forward when paused and the held set is the shown one" do
    expect(key(paused: true, held_is_shown: true, missing_set: :start_generation)).to eq("dashboard.stale_set.carried_forward")
  end

  it "puts the carry-forward sentence ahead of the weekend, since a held set moves on a weekend too" do
    expect(key(paused: true, held_is_shown: true, missing_set: :weekend)).to eq("dashboard.stale_set.carried_forward")
  end

  it "says generation is paused when paused with nothing to carry forward" do
    expect(key(paused: true, missing_set: :weekend)).to eq("dashboard.stale_set.paused")
    expect(key(paused: true, missing_set: :trial_ended)).to eq("dashboard.stale_set.paused")
  end

  it "says only to reload when the shown set was already submitted" do
    expect(key(shown_submitted: true)).to eq("dashboard.stale_set.submitted")
    expect(key(shown_submitted: true, paused: true)).to eq("dashboard.stale_set.submitted")
  end

  it "never reads a held set as carried forward without a pause" do
    expect(key(held_is_shown: true)).to eq("dashboard.stale_set.starts_generation")
  end

  it "has a sentence for every state MissingSetState returns when no generation was just asked for" do
    flags = %i[trial_ended provider_ready failed_today weekend paused]
    [ true, false ].repeated_permutation(flags.size).each do |values|
      inputs = flags.zip(values).to_h
      state = MissingSetState.for(manual_trigger: false, **inputs)

      sentence = key(paused: inputs[:paused], missing_set: state)
      expect(I18n.exists?(sentence, :en)).to be(true), "#{inputs} -> #{state.inspect}"
    end
  end

  it "raises on a missing-set answer it has no sentence for" do
    expect { key(missing_set: :generating) }.to raise_error(ArgumentError)
  end

  it "names the newer-set and replaced sentences, and raises on any other freshness answer" do
    expect(described_class.newer_set(:stale)).to eq("dashboard.stale_set.newer")
    expect(described_class.newer_set(:replaced)).to eq("dashboard.stale_set.replaced")
    expect { described_class.newer_set(:current) }.to raise_error(KeyError)
  end

  it "names only keys the locale file holds" do
    keys = %i[weekend start_generation].map { |state| key(missing_set: state) } +
           [ key(paused: true, held_is_shown: true), key(paused: true), key(shown_submitted: true),
             described_class.newer_set(:stale), described_class.newer_set(:replaced) ]
    keys.each { |name| expect(I18n.exists?(name, :en)).to be(true), name }
  end
end
