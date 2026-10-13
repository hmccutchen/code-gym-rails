require "rails_helper"

RSpec.describe FeaturedConcept, type: :model do
  let(:user) { create_user_with_key }
  let(:monday) { Date.new(2026, 9, 7) }

  def meet(concept, date:, owner: user, **section)
    submit_set_showing(owner, concept, date: date, **section)
  end

  # A fresh row each call, as each request loads one: User memoizes its exposure index.
  def featured(on, owner: user) = described_class.for(User.find(owner.id), today: on)

  def pair(row) = row && [ row.concept, row.bucket ]

  it "features nothing and stores nothing before the user has met a concept" do
    expect(featured(monday)).to be_nil
    expect(described_class.count).to eq(0)
  end

  it "stores a met concept against the Monday of the week it was asked about" do
    meet("n_plus_one", date: monday - 3)

    row = featured(monday + 2)

    expect(pair(row)).to eq(%w[n_plus_one ruby_rails])
    expect(row.week_of).to eq(monday)
  end

  it "keeps one concept from Monday through Sunday, even as new work arrives" do
    meet("n_plus_one", date: monday - 3)
    picked = featured(monday)
    meet("memoization", date: monday + 1)

    expect((monday..monday + 6).map { |day| featured(day) }).to all(eq(picked))
  end

  it "moves to another met concept the next Monday" do
    meet("n_plus_one", date: monday - 3)
    meet("memoization", date: monday - 2)

    expect(pair(featured(monday + 7))).not_to eq(pair(featured(monday)))
  end

  it "prefers a concept developing toward a rung over one only skipped" do
    meet("memoization", date: monday - 3, answered: false)
    meet("n_plus_one", date: monday - 2)

    expect(pair(featured(monday))).to eq(%w[n_plus_one ruby_rails])
  end

  it "features a concept met only in a skipped section" do
    meet("memoization", date: monday - 3, answered: false)

    expect(pair(featured(monday))).to eq(%w[memoization ruby_rails])
  end

  it "features nothing while every met concept is held, until something new is met" do
    meet("n_plus_one", date: monday - 3, ai: "solid")

    expect(featured(monday)).to be_nil
    expect(described_class.count).to eq(0)

    meet("memoization", date: monday + 1)

    expect(pair(featured(monday + 1))).to eq(%w[memoization ruby_rails])
  end

  it "picks for each user from that user's own work" do
    other = create_user_with_key(email: "other@example.com", name: "Other")
    meet("n_plus_one", date: monday - 3)
    meet("memoization", date: monday - 3, owner: other)

    expect(pair(featured(monday))).to eq(%w[n_plus_one ruby_rails])
    expect(pair(featured(monday, owner: other))).to eq(%w[memoization ruby_rails])
  end

  it "resolves the week in the user's own zone" do
    user.update!(time_zone: "America/Los_Angeles")
    meet("n_plus_one", date: monday - 3)

    # 03:00 UTC on Monday is still Sunday evening in Los Angeles.
    row = travel_to(Time.utc(2026, 9, 14, 3)) { Time.use_zone(user.effective_time_zone) { described_class.for(user) } }

    expect(row.week_of).to eq(monday)
  end

  it "re-picks in place when a language change leaves the stored concept outside the slice" do
    meet("n_plus_one", date: monday - 3)
    meet("caching_strategy", date: monday - 2, section: "architecture")
    stored = featured(monday)
    expect(pair(stored)).to eq(%w[n_plus_one ruby_rails])

    user.update!(language: "javascript")
    repicked = featured(monday + 2)

    expect(repicked.id).to eq(stored.id)
    expect(pair(repicked)).to eq(%w[caching_strategy architecture])
  end

  it "re-picks in place when the stored concept has left the vocabulary" do
    meet("n_plus_one", date: monday - 3)
    stale = user.featured_concepts.create!(week_of: monday, concept: "retired_concept", bucket: "ruby_rails")

    expect(featured(monday + 1)).to have_attributes(id: stale.id, concept: "n_plus_one")
  end

  it "removes a stored pick that no longer fits when nothing else qualifies" do
    stale = user.featured_concepts.create!(week_of: monday, concept: "retired_concept", bucket: "ruby_rails")

    expect(featured(monday + 1)).to be_nil
    expect(described_class.exists?(stale.id)).to be(false)
  end

  it "picks from either language for a mixed user" do
    user.update!(language: "mixed")
    meet("caching_strategy", date: monday - 3, section: "architecture")

    expect(pair(featured(monday))).to eq(%w[caching_strategy architecture])
  end

  # The read is faked to miss once, so the insert really collides with the winner's row.
  def losing_the_race
    missed_once = false
    allow(user.featured_concepts).to receive(:find_by).and_wrap_original do |original, *args|
      next original.call(*args) if missed_once

      missed_once = true
      nil
    end

    yield
  end

  it "hands back the winner's pick when its own insert loses the race" do
    meet("n_plus_one", date: monday - 3)
    winner = user.featured_concepts.create!(week_of: monday, concept: "n_plus_one", bucket: "ruby_rails")

    losing_the_race { expect(described_class.for(user, today: monday)).to eq(winner) }
  end

  # Transactional specs open a non-joinable wrapper, which masks a missing requires_new; a caller's does not.
  it "recovers from the collision inside a caller's own transaction" do
    meet("n_plus_one", date: monday - 3)
    winner = user.featured_concepts.create!(week_of: monday, concept: "n_plus_one", bucket: "ruby_rails")

    losing_the_race { expect(described_class.transaction { described_class.for(user, today: monday) }).to eq(winner) }
  end

  it "spends nothing to pick" do
    meet("n_plus_one", date: monday - 3)

    expect { featured(monday) }.not_to change(ApiUsage, :count)
  end

  describe "#marks?" do
    let(:featured) { described_class.new(concept: "missing_constraint", bucket: "ruby_rails") }

    it "marks a section carrying the same concept in the same bucket" do
      expect(featured.marks?(concept: "missing_constraint", bucket: "ruby_rails")).to be(true)
    end

    # Data-modeling concepts sit in both language vocabularies, so the name alone is not enough.
    it "leaves the same concept in another bucket unmarked" do
      expect(featured.marks?(concept: "missing_constraint", bucket: "javascript")).to be(false)
    end

    it "leaves a section with no concept unmarked" do
      expect(featured.marks?(concept: nil, bucket: "ruby_rails")).to be(false)
    end
  end
end
