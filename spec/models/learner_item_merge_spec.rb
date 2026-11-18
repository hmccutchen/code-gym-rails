require "rails_helper"

RSpec.describe LearnerItem, ".merge!" do
  let(:user) { User.create!(email: "merge@example.com", time_zone: "UTC") }
  let(:set_date) { Date.new(2026, 11, 16) }

  around { |example| travel_to(Time.utc(2026, 11, 16, 20)) { example.run } }

  def reference(date = set_date, source: "duck", section: "code_review")
    { "date" => date.iso8601, "source" => source, "section" => section }
  end

  def reply_item(concept: "n_plus_one", kind: "misconception", term: nil, label: "Each row runs its own query.",
                 bucket: "ruby_rails", evidence: [ reference ])
    LearnerItemsReply::Item.new(concept: concept, bucket: bucket, kind: kind, term: term, label: label, evidence: evidence)
  end

  def stored(concept: "n_plus_one", kind: "misconception", term: nil, status: "open", label: "The owner's label.",
             evidence_on: set_date - 3, created_on: evidence_on, **attrs)
    described_class.create!(user: user, concept: concept, bucket: "ruby_rails", kind: kind, term: term, label: label,
                            status: status, evidence: [ reference(evidence_on) ], came_up_on: [ evidence_on.iso8601 ],
                            expires_on: described_class.expiry_for(newest_evidence_on: evidence_on, created_on: created_on),
                            created_at: created_on.to_time, **attrs)
  end

  let(:all_sources) { -> { LearnerItem::EVIDENCE_SOURCES } }

  def merge(*items, date: set_date, still_there: all_sources) = described_class.merge!(user, items, set_date: date, still_there: still_there)

  def concepts = %w[n_plus_one memoization service_objects scope_chaining transaction_safety caching]

  describe "an open item with the same key" do
    it "absorbs the reply item, gaining its evidence and the day, moving its expiry, and keeping its own label" do
      open_item = stored

      result = merge(reply_item(label: "A reworded label."))

      open_item.reload
      expect(open_item.label).to eq("The owner's label.")
      expect(open_item.evidence.first).to eq(reference)
      expect(open_item.came_up_on).to eq([ set_date.iso8601, (set_date - 3).iso8601 ])
      expect(open_item.expires_on).to eq(set_date + LearnerItem::EXPIRES_AFTER_EVIDENCE)
      expect(described_class.count).to eq(1)
      expect(result).to have_attributes(written: 0, absorbed: 1, dropped: {})
    end

    it "keeps the newest five references" do
      open_item = stored
      open_item.update!(evidence: (1..5).map { |back| reference(set_date - back) })

      merge(reply_item(evidence: [ reference(source: "answer") ]))

      expect(open_item.reload.evidence.size).to eq(LearnerItem::MAX_EVIDENCE)
      expect(open_item.evidence.first).to eq(reference(source: "answer"))
      expect(open_item.evidence).not_to include(reference(set_date - 5))
    end

    it "never moves the expiry past the longest life from creation" do
      open_item = stored(evidence_on: set_date - 35)
      open_item.update!(evidence: [ reference(set_date - 2) ], expires_on: set_date + 1)

      merge(reply_item)

      expect(open_item.reload.expires_on).to eq(set_date - 35 + LearnerItem::LONGEST_LIFE)
    end

    it "merges a reply carrying another item's id or a made-up one, leaving the item that id named untouched" do
      target = stored
      other = stored(concept: "memoization", kind: "concept")
      before = other.attributes

      day = LearnerItemsReply::Day.new(date: set_date, duck_sections: %w[code_review], answered_sections: [], note: false,
                                       explanation_section: nil)
      [ other.id, 999_999 ].each do |id|
        raw = { "items" => [ { "id" => id, "concept" => "n_plus_one", "bucket" => "ruby_rails", "kind" => "misconception",
                               "label" => "Reworded.", "evidence" => [ { "source" => "duck", "section" => "code_review" } ] } ] }
        described_class.merge!(user, LearnerItemsReply.parse(raw, day: day, buckets: %w[ruby_rails]).items, set_date: set_date,
                                     still_there: all_sources)
      end

      expect(other.reload.attributes).to eq(before)
      expect(target.reload.evidence.first).to eq(reference)
      expect(described_class.where(status: "open").count).to eq(2)
    end

    it "matches a term without case and with runs of spaces collapsed" do
      open_item = stored(kind: "term", term: "Eager Load")

      merge(reply_item(kind: "term", term: "eager  load"))

      expect(open_item.reload.came_up_on.first).to eq(set_date.iso8601)
      expect(described_class.count).to eq(1)
    end
  end

  describe "inside one reply" do
    it "collapses two matching items into one row with both evidence sets and the first label" do
      merge(reply_item(label: "First label."), reply_item(label: "Second label.", evidence: [ reference(source: "answer") ]))

      item = described_class.sole
      expect(item.label).to eq("First label.")
      expect(item.evidence).to contain_exactly(reference, reference(source: "answer"))
    end

    it "counts repeats apart from new items, keeping five repeats and three new items and dropping a fourth new one" do
      concepts.first(5).each { |concept| stored(concept: concept) }
      repeats = concepts.first(5).map { |concept| reply_item(concept: concept, label: "Reworded.") }
      fresh = %w[memoization service_objects scope_chaining transaction_safety].map { |concept| reply_item(concept: concept, kind: "concept") }

      result = merge(*repeats, *fresh)

      expect(result).to have_attributes(absorbed: 5, written: 3, dropped: { over_limit: 1 })
      expect(described_class.where(kind: "concept").pluck(:concept)).to contain_exactly("memoization", "service_objects", "scope_chaining")
      expect(described_class.where(kind: "misconception").pluck(:label).uniq).to eq([ "The owner's label." ])
    end

    it "counts a repeat of a closed item as new" do
      stored(status: "expired", closed_on: set_date - 1)
      fresh = %w[memoization service_objects scope_chaining].map { |concept| reply_item(concept: concept, kind: "concept") }

      result = merge(reply_item, *fresh)

      expect(result.dropped).to eq(over_limit: 1)
      expect(described_class.where(status: "open", kind: "misconception")).to exist
    end
  end

  describe "an item used in the last 30 days" do
    it "holds back a term used 10 days before and writes one used 31 days before" do
      stored(kind: "term", term: "eager load", status: "used", used_on: set_date - 10, closed_on: set_date - 10)

      expect(merge(reply_item(kind: "term", term: "eager load")).dropped).to eq(recently_used: 1)
      expect(described_class.where(status: "open")).to be_empty

      described_class.update_all(used_on: set_date - 31)
      expect(merge(reply_item(kind: "term", term: "eager load")).written).to eq(1)
    end

    it "recreates a used misconception only from the shaped set onward" do
      stored(status: "used", used_on: set_date, closed_on: set_date)

      before = merge(reply_item(evidence: [ reference(set_date - 1) ]), date: set_date - 1)
      expect(before.dropped).to eq(recently_used: 1)

      mixed = merge(reply_item(evidence: [ reference(set_date - 1, source: "answer"), reference ]))
      expect(mixed.written).to eq(1)
      expect(described_class.find_by(status: "open").evidence).to eq([ reference ])
    end

    it "writes a used misconception's match from a later set" do
      stored(status: "used", used_on: set_date - 2, closed_on: set_date - 2)

      expect(merge(reply_item).written).to eq(1)
    end

    it "no longer holds back a used term that was deleted" do
      stored(kind: "term", term: "eager load", status: "used", used_on: set_date - 1, closed_on: set_date - 1).destroy!

      expect(merge(reply_item(kind: "term", term: "eager load")).written).to eq(1)
    end
  end

  describe "a key the owner dismissed" do
    it "writes the new row with returned_after, the latest close, and leaves the dismissed rows as they were" do
      older = stored(status: "dismissed", closed_on: set_date - 20)
      newer = stored(status: "dismissed", closed_on: set_date - 5)

      merge(reply_item)

      expect(described_class.find_by(status: "open").returned_after).to eq(set_date - 5)
      expect([ older.reload.status, newer.reload.status ]).to eq(%w[dismissed dismissed])
    end

    it "sets no returned_after once the dismissed item was deleted" do
      stored(status: "dismissed", closed_on: set_date - 5).destroy!

      merge(reply_item)

      expect(described_class.find_by(status: "open").returned_after).to be_nil
    end
  end

  describe "an insert" do
    it "writes the label, the set's date and an expiry from the newest evidence" do
      merge(reply_item(kind: "term", term: "eager load"))

      expect(described_class.sole).to have_attributes(status: "open", term: "eager load", came_up_on: [ set_date.iso8601 ],
                                                      evidence: [ reference ], expires_on: set_date + LearnerItem::EXPIRES_AFTER_EVIDENCE)
    end
  end

  describe "the open-item limits" do
    it "displaces the open items with the oldest newest evidence past five" do
      concepts.first(4).each_with_index { |concept, index| stored(concept: concept, evidence_on: set_date - 10 + index) }
      fresh = %w[memoization caching].map { |concept| reply_item(concept: concept, kind: "concept") }

      merge(*fresh)

      expect(described_class.where(status: "open").count).to eq(LearnerItem::MAX_OPEN)
      displaced = described_class.find_by(concept: "n_plus_one", kind: "misconception")
      expect(displaced).to have_attributes(status: "expired", closed_on: set_date)
    end

    it "expires an overdue open row first, so a reply for its key writes a new row" do
      overdue = stored(evidence_on: set_date - 20)
      overdue.update_columns(expires_on: set_date - 1)

      result = merge(reply_item)

      expect(overdue.reload).to have_attributes(status: "expired", closed_on: set_date - 1)
      expect(result.written).to eq(1)
      expect(described_class.where(status: "open").count).to eq(1)
    end

    it "treats a unique violation from a writer that skipped the lock as a merge into the existing row" do
      racer = nil
      allow(described_class).to receive(:open_by_key).and_wrap_original do |original, *args|
        rows = original.call(*args)
        racer ||= stored(label: "Written meanwhile.")
        rows
      end

      result = merge(reply_item)

      expect(result).to have_attributes(written: 0, absorbed: 1)
      expect(racer.reload.evidence.first).to eq(reference)
      expect(described_class.where(status: "open").count).to eq(1)
    end

    it "writes nothing for an account deleted before the merge" do
      items = [ reply_item ]
      User.where(id: user.id).delete_all

      expect(described_class.merge!(user, items, set_date: set_date, still_there: all_sources)).to eq(:deleted)
    end
  end

  describe "evidence deleted while the call was out" do
    let(:note_gone) { -> { %w[duck answer explanation] } }

    it "writes no item that cited a note deleted meanwhile, even one with other evidence" do
      result = merge(reply_item(evidence: [ reference(source: "duck"), { "date" => set_date.iso8601, "source" => "note" } ]),
                     reply_item(concept: "memoization", evidence: [ reference(source: "answer") ]),
                     still_there: note_gone)

      expect(described_class.pluck(:concept)).to eq([ "memoization" ])
      expect(result).to have_attributes(written: 1, dropped: { evidence_deleted: 1 })
    end

    it "lets no open item absorb a repeat citing a deleted explanation" do
      open_item = stored
      merge(reply_item(evidence: [ reference(source: "explanation") ]), still_there: -> { %w[duck answer note] })

      expect(open_item.reload.evidence).to eq([ reference(set_date - 3) ])
    end

    it "writes nothing once the set is no longer the one read" do
      stored(concept: "memoization", kind: "concept")

      result = merge(reply_item, reply_item(concept: "caching", kind: "concept"), still_there: -> { })

      expect(described_class.pluck(:concept)).to eq([ "memoization" ])
      expect(result).to eq(:replaced)
    end

    it "asks what is still there after it takes the user row lock" do
      order = []
      allow(User).to receive(:lock).and_wrap_original { |original, *args| (order << :user_lock) && original.call(*args) }

      merge(reply_item, still_there: -> { (order << :check) && LearnerItem::EVIDENCE_SOURCES })

      expect(order).to eq(%i[user_lock check])
    end
  end
end

RSpec.describe LearnerItem, ".merge! under concurrency", type: :model do
  self.use_transactional_tests = false

  let!(:user) { User.create!(email: "merge-race@example.com", time_zone: "UTC") }

  after { User.where(email: "merge-race@example.com").destroy_all }

  def reply_item(concept)
    LearnerItemsReply::Item.new(concept: concept, bucket: "ruby_rails", kind: "concept", term: nil, label: "Practise this.",
                                evidence: [ { "date" => Date.current.iso8601, "source" => "note" } ])
  end

  # Each merge waits up to a second for the other to read the open items, so without the user row lock both read none.
  it "holds the five-item cap under two concurrent merges" do
    batches = [ %w[n_plus_one memoization service_objects], %w[scope_chaining transaction_safety caching] ]
    both_read = Concurrent::CountDownLatch.new(batches.size)
    allow(LearnerItem).to receive(:open_by_key).and_wrap_original do |original, *args|
      original.call(*args).tap do
        both_read.count_down
        both_read.wait(1)
      end
    end

    batches.map { |concepts|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          LearnerItem.merge!(user, concepts.map { |concept| reply_item(concept) }, set_date: Date.current,
                                                                                   still_there: -> { LearnerItem::EVIDENCE_SOURCES })
        end
      end
    }.each(&:join)

    expect(LearnerItem.where(user: user, status: "open").count).to eq(LearnerItem::MAX_OPEN)
    expect(LearnerItem.where(user: user).count).to eq(6)
  end
end
