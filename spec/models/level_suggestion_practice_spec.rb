require "rails_helper"

RSpec.describe LevelSuggestion do
  let(:today) { Date.new(2026, 11, 6) }

  def result(age, concept: "memoization", rating: "solid", self_rating: "right_level")
    described_class::Result.new(date: today - age, level: "mid_level", ai_rating: rating,
      self_rating: self_rating, concept: concept, bucket: "ruby_rails")
  end

  def offer(entries, on: today)
    described_class.proposal(levels: { "pattern" => "mid_level" }, locked: [],
      results: { "pattern" => entries }, cutoffs: {}, today: on)
  end

  it "retains age 179 but excludes 180, and requires own-kind freshness at 29 not 30" do
    expect(offer([ 0, 40, 80, 120, 179 ].map { |age| result(age) })).to be_present
    expect(offer([ 0, 40, 80, 120, 180 ].map { |age| result(age) })).to be_nil
    entries = [ 29, 40, 80, 120, 179 ].map { |age| result(age) }
    expect(offer(entries)).to be_present
    expect(offer(entries, on: today + 1)).to be_nil
  end

  it "requires difficulty across valid concept identities for a lower offer" do
    first = result(0, rating: "developing", self_rating: "too_hard")
    repeated = result(1, self_rating: "too_hard")
    expect(offer([ first, repeated ])).to be_nil
    distinct = result(1, concept: "n_plus_one", self_rating: "too_hard")
    expect(offer([ first, distinct ]).basis).to eq(:struggling)
    expect(offer([ first, result(1, concept: "invented", self_rating: "too_hard") ])).to be_nil
  end

  it "never creates an offer from elapsed time" do
    entries = [ 0, 1, 2, 60 ].map { |age| result(age) }
    181.times { |offset| expect(offer(entries, on: today + offset)).to be_nil }
  end
end
