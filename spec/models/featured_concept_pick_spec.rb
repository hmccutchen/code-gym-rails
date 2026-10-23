require "rails_helper"

# Pure: a stand-in ledger answers the two questions the pick asks, so no example touches the database.
RSpec.describe FeaturedConceptPick do
  let(:ledger_class) do
    Struct.new(:toward, :holding) do
      def developing_toward(concept, bucket) = toward[[ concept, bucket ]]
      def held(concept, bucket) = holding[[ concept, bucket ]]
    end
  end

  let(:n_plus_one) { %w[n_plus_one ruby_rails] }
  let(:caching)    { %w[caching_strategy architecture] }
  let(:idempotency) { %w[idempotency_at_scale architecture] }

  def ledger(developing: {}, held: {}) = ledger_class.new(developing, held)

  def pick(met, ledger: self.ledger, last_featured: {}, previous: nil)
    described_class.pick(met: met, ledger: ledger, last_featured: last_featured, previous: previous)
  end

  it "picks nothing when nothing has been met" do
    expect(pick([])).to be_nil
  end

  it "prefers a concept developing toward a rung over one with no evidence yet" do
    developing = ledger(developing: { caching => "senior" })

    expect(pick([ n_plus_one, caching ], ledger: developing)).to eq(caching)
  end

  it "takes a met concept with no evidence when none is developing" do
    expect(pick([ n_plus_one ])).to eq(n_plus_one)
  end

  it "never picks a held concept" do
    held = ledger(held: { n_plus_one => "senior" })

    expect(pick([ n_plus_one, caching ], ledger: held)).to eq(caching)
  end

  it "picks nothing when every met concept is held" do
    held = ledger(held: { n_plus_one => "senior", caching => "junior" })

    expect(pick([ n_plus_one, caching ], ledger: held)).to be_nil
  end

  it "counts a held concept still developing toward a higher rung as developing" do
    climbing = ledger(held: { n_plus_one => "junior" }, developing: { n_plus_one => "mid_level" })

    expect(pick([ caching, n_plus_one ], ledger: climbing)).to eq(n_plus_one)
  end

  it "skips last week's concept when another candidate exists, even one with no evidence" do
    developing = ledger(developing: { caching => "senior" })

    expect(pick([ n_plus_one, caching ], ledger: developing, previous: caching)).to eq(n_plus_one)
  end

  it "repeats last week's concept when it is the only candidate" do
    expect(pick([ caching ], previous: caching)).to eq(caching)
  end

  it "puts a never-featured concept ahead of one featured before" do
    expect(pick([ n_plus_one, caching ], last_featured: { n_plus_one => Date.new(2026, 9, 7) })).to eq(caching)
  end

  it "picks the concept featured longest ago once every candidate has had a turn" do
    shown = { n_plus_one => Date.new(2026, 9, 21), caching => Date.new(2026, 9, 7) }

    expect(pick([ n_plus_one, caching ], last_featured: shown)).to eq(caching)
  end

  it "breaks a tie in slice order" do
    expect(pick([ idempotency, caching ])).to eq(idempotency)
  end
end
