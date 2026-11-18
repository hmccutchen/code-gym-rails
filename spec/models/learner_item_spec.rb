require "rails_helper"

RSpec.describe LearnerItem do
  include AuthHelpers

  let(:user) { create_user_with_key }
  let(:duck) { { "date" => "2026-11-16", "source" => "duck", "section" => "code_review" } }

  def item(**attrs)
    described_class.new(user: user, concept: "open_closed", bucket: "ruby_rails", kind: "concept",
                        label: "Reaches for a subclass where a new case only needs a new object.",
                        evidence: [ duck ], came_up_on: [ "2026-11-16" ], expires_on: Date.new(2026, 11, 30), **attrs)
  end

  def refused(record) = record.tap(&:validate).errors.attribute_names

  it "accepts the three kinds and refuses a strength" do
    expect(described_class::KINDS).to eq(%w[term misconception concept])
    %w[misconception concept].each { |kind| expect(item(kind: kind)).to be_valid }
    expect(item(kind: "term", term: "STI")).to be_valid
    expect(refused(item(kind: "strength"))).to include(:kind)
  end

  it "goes with its owner when an account is anonymized, and leaves other accounts' items" do
    item.save!
    other = create_user_with_key(email: "other-#{SecureRandom.hex(4)}@example.com")
    kept = item(user: other).tap(&:save!)

    expect { user.anonymize! }.to change { described_class.where(user: user).count }.from(1).to(0)
    expect(described_class.exists?(kept.id)).to be(true)
  end

  it "can still be closed after its concept or a section it cites leaves the registry" do
    retired_concept = item.tap(&:save!)
    retired_concept.update_columns(concept: "retired_concept")
    retired_section = item(concept: "dependency_inversion").tap(&:save!)
    retired_section.update_columns(evidence: [ duck.merge("section" => "retired_kind") ])

    expect { retired_concept.reload.update!(status: "dismissed") }.not_to raise_error
    expect { retired_section.reload.update!(status: "dismissed") }.not_to raise_error
    expect(retired_concept.update(concept: "still_not_a_concept")).to be(false)
    expect(retired_section.update(evidence: [ duck.merge("section" => "not_a_section") ])).to be(false)
  end

  it "accepts only a concept and bucket the vocabulary knows" do
    expect(refused(item(concept: "not_a_concept"))).to include(:concept)
    expect(refused(item(bucket: "not_a_bucket"))).to include(:concept)
  end

  it "refuses an unknown kind in the database too" do
    row = item.tap(&:save!)

    expect { row.update_columns(kind: "strength") }.to raise_error(ActiveRecord::StatementInvalid, /learner_items_kind/)
  end

  it "refuses an unknown status in the database too" do
    row = item.tap(&:save!)

    expect { row.update_columns(status: "closed") }.to raise_error(ActiveRecord::StatementInvalid, /learner_items_status/)
  end

  it "refuses a term on an item that is not a term in the database too" do
    row = item.tap(&:save!)

    expect { described_class.where(id: row.id).update_all(term: "Liskov") }
      .to raise_error(ActiveRecord::StatementInvalid, /learner_items_term_only_on_terms/)
  end

  it "starts open and accepts only the four statuses" do
    expect(described_class.new.status).to eq("open")
    described_class::STATUSES.each { |status| expect(item(status: status)).to be_valid }
    expect(described_class::STATUSES).to eq(%w[open used dismissed expired])
    expect(refused(item(status: "deleted"))).to include(:status)
  end

  it "holds a label of one line and at most 160 characters" do
    expect(item(label: "a" * 160)).to be_valid
    expect(refused(item(label: "a" * 161))).to include(:label)
    expect(refused(item(label: "first line\nsecond line"))).to include(:label)
    expect(refused(item(label: ""))).to include(:label)
  end

  it "holds a term only on a term item, of at most 40 allowed characters" do
    expect(item(kind: "term", term: "C# .NET/x_y+z-w")).to be_valid
    expect(item(kind: "term", term: "a" * 40)).to be_valid
    expect(refused(item(kind: "term", term: "a" * 41))).to include(:term)
    expect(refused(item(kind: "term", term: "drop; table"))).to include(:term)
    expect(refused(item(kind: "term", term: "<b>"))).to include(:term)
    expect(refused(item(kind: "term", term: nil))).to include(:term)
    expect(refused(item(kind: "concept", term: "STI"))).to include(:term)
  end

  it "holds at most five evidence references in the date, source and section shape" do
    note = { "date" => "2026-11-16", "source" => "note" }
    answer = duck.merge("source" => "answer")
    explanation = duck.merge("source" => "explanation")

    expect(item(evidence: [ duck, note, answer, explanation, duck.merge("date" => "2026-11-17") ])).to be_valid
    expect(refused(item(evidence: [ duck ] * 6))).to include(:evidence)
    expect(refused(item(evidence: [ note.merge("section" => "code_review") ]))).to include(:evidence)
    expect(refused(item(evidence: [ duck.except("section") ]))).to include(:evidence)
    expect(refused(item(evidence: [ duck.merge("source" => "review") ]))).to include(:evidence)
    expect(refused(item(evidence: [ duck.merge("date" => "yesterday") ]))).to include(:evidence)
    expect(refused(item(evidence: [ duck.merge("text" => "what they said") ]))).to include(:evidence)
    expect(refused(item(evidence: [ duck.merge("section" => "not_a_section") ]))).to include(:evidence)
    expect(refused(item(evidence: { "0" => duck }))).to include(:evidence)
  end

  it "holds at most ten distinct dates it came up on" do
    dates = (1..10).map { |day| Date.new(2026, 11, day).iso8601 }

    expect(item(came_up_on: dates)).to be_valid
    expect(refused(item(came_up_on: dates + [ "2026-11-11" ]))).to include(:came_up_on)
    expect(refused(item(came_up_on: [ "2026-11-16", "2026-11-16" ]))).to include(:came_up_on)
    expect(refused(item(came_up_on: [ "16 November" ]))).to include(:came_up_on)
  end

  describe ".expiry_for" do
    let(:created_on) { Date.new(2026, 11, 1) }

    it "is 14 days after the newest evidence" do
      expect(described_class.expiry_for(newest_evidence_on: Date.new(2026, 11, 5), created_on: created_on)).to eq(Date.new(2026, 11, 19))
    end

    it "is never more than 42 days after the item was created" do
      expect(described_class.expiry_for(newest_evidence_on: Date.new(2026, 12, 10), created_on: created_on)).to eq(Date.new(2026, 12, 13))
    end
  end

  describe "#matching_key" do
    it "is the concept, bucket and kind, with a term compared without case and with its spaces collapsed" do
      one = item(kind: "term", term: "Single  Table Inheritance")
      other = item(kind: "term", term: " single table   inheritance ")

      expect(one.matching_key).to eq(other.matching_key)
      expect(one.matching_key).to eq([ "open_closed", "ruby_rails", "term", "single table inheritance" ])
      expect(item.matching_key).to eq([ "open_closed", "ruby_rails", "concept", "" ])
      expect(item.matching_key).not_to eq(item(bucket: "javascript").matching_key)
      expect(item.matching_key).not_to eq(item(kind: "misconception").matching_key)
    end
  end

  it "hides the label and the term from inspect" do
    shown = item(kind: "term", term: "STI", label: "Mixes up STI with polymorphism.").inspect

    expect(shown).not_to include("STI", "polymorphism")
    expect(shown).to include("label: [FILTERED]", "term: [FILTERED]")
  end

  describe ".earlier_labels" do
    let(:set_date) { Date.new(2026, 11, 16) }
    let(:concepts) { %w[n_plus_one memoization service_objects scope_chaining transaction_safety caching idempotency authorization] }

    def closed(concept, closed_on, status: "expired", label: "#{concept} on #{closed_on}")
      item(concept: concept, status: status, closed_on: closed_on, label: label).tap(&:save!)
    end

    it "lists items used, dismissed or expired in the last 30 days, newest first, with no id" do
      closed("n_plus_one", set_date - 2, status: "used")
      closed("memoization", set_date - 1, status: "dismissed")
      closed("caching", set_date - 31)
      item.tap(&:save!)

      labels = described_class.earlier_labels(user, set_date: set_date)

      expect(labels).to eq([
        { concept: "memoization", bucket: "ruby_rails", kind: "concept", term: nil, label: "memoization on 2026-11-15", status: "dismissed", date: "2026-11-15" },
        { concept: "n_plus_one", bucket: "ruby_rails", kind: "concept", term: nil, label: "n_plus_one on 2026-11-14", status: "used", date: "2026-11-14" }
      ])
    end

    it "keeps at most three labels a concept and twenty in all, the newest" do
      (1..5).each { |back| closed("n_plus_one", set_date - back) }
      concepts.drop(1).each_with_index { |concept, index| (1..3).each { |back| closed(concept, set_date - 3 - (3 * index) - back) } }

      labels = described_class.earlier_labels(user, set_date: set_date)

      expect(labels.size).to eq(LearnerItem::MAX_EARLIER_LABELS)
      expect(labels.count { |label| label[:concept] == "n_plus_one" }).to eq(LearnerItem::EARLIER_LABELS_PER_CONCEPT)
      expect(labels.first(3).map { |label| label[:date] }).to eq(%w[2026-11-15 2026-11-14 2026-11-13])
      expect(labels.map { |label| label[:date] }).to eq(labels.map { |label| label[:date] }.sort.reverse)
      expect(labels.map { |label| label[:concept] }).not_to include("authorization")
      expect(labels.count { |label| label[:concept] == "idempotency" }).to eq(2)
    end
  end

  it "gives the extraction prompt its open items without ids" do
    item.tap(&:save!)

    expect(described_class.open_for_prompt(user)).to eq([ { concept: "open_closed", bucket: "ruby_rails", kind: "concept", term: nil,
                                                            label: "Reaches for a subclass where a new case only needs a new object." } ])
  end
end
