# Design notes: docs/code-notes/app/models/learner_item/merge.md
class LearnerItem::Merge
  Result = Data.define(:written, :absorbed, :dropped)

  # still_there returns the evidence sources that still exist for the set read, or nil once the set was replaced or forgotten.
  def self.call(user, items, set_date:, still_there:)
    LearnerItem.transaction do
      owner = User.lock.find_by(id: user.id)
      next :deleted if owner.nil? || owner.anonymized?

      sources = still_there.call
      next :replaced unless sources

      new(owner, set_date).run(items, sources)
    end
  end

  def initialize(owner, set_date)
    @owner = owner
    @set_date = set_date
    @today = LearnerItem.today_for(owner)
    @written = 0
    @absorbed = 0
    @dropped = Hash.new(0)
  end

  def run(items, sources)
    LearnerItem.expire_overdue!(@owner, today: @today)
    open = LearnerItem.open_by_key(@owner)
    repeats, fresh = collapse(still_supported(items, sources)).partition { |item| open.key?(key_of(item)) }
    repeats.each { |item| absorb(open.fetch(key_of(item)), item) }
    @dropped[:over_limit] += fresh.size - LearnerItem::MAX_NEW_PER_DAY if fresh.size > LearnerItem::MAX_NEW_PER_DAY
    fresh.first(LearnerItem::MAX_NEW_PER_DAY).each { |item| insert(item) }
    LearnerItem.displace_past_limit!(@owner, today: @today)
    Result.new(written: @written, absorbed: @absorbed, dropped: @dropped.to_h)
  end

  private

  def still_supported(items, sources)
    kept, gone = items.partition { |item| cites_only(item, sources) }
    @dropped[:evidence_deleted] += gone.size if gone.any?
    kept
  end

  def cites_only(item, sources)
    item.evidence.all? { |reference| reference["date"] != @set_date.iso8601 || sources.include?(reference["source"]) }
  end

  def key_of(item) = LearnerItem.matching_key(concept: item.concept, bucket: item.bucket, kind: item.kind, term: item.term)

  def collapse(items)
    items.group_by { |item| key_of(item) }.values.map do |same|
      same.first.with(evidence: same.flat_map(&:evidence).uniq)
    end
  end

  def absorb(row, item)
    evidence = kept_evidence(item.evidence + row.evidence)
    created_on = row.created_at.in_time_zone(@owner.effective_time_zone).to_date
    row.update!(evidence: evidence, came_up_on: ([ @set_date.iso8601 ] | row.came_up_on).sort.reverse.first(LearnerItem::MAX_CAME_UP_ON),
                expires_on: LearnerItem.expiry_for(newest_evidence_on: newest_date(evidence), created_on: created_on))
    @absorbed += 1
  end

  def insert(item)
    closed = closed_rows(item)
    evidence = evidence_past_recent_use(item, closed)
    return @dropped[:recently_used] += 1 if evidence.empty?

    write(item, kept_evidence(evidence),
          returned_after: closed.select { |row| row.status == "dismissed" }.filter_map(&:closed_on).max)
  end

  # Rule 3: a term used recently is held back outright; another kind keeps only evidence from the shaped set onward.
  def evidence_past_recent_use(item, closed)
    used_on = closed.select { |row| row.status == "used" && row.used_on && row.used_on >= @set_date - LearnerItem::RECENT_DAYS }
                    .map(&:used_on).max
    return item.evidence unless used_on
    return [] if item.kind == "term"

    item.evidence.select { |reference| Date.iso8601(reference["date"]) >= used_on }
  end

  def write(item, evidence, returned_after:)
    LearnerItem.transaction(requires_new: true) do
      LearnerItem.create!(user: @owner, concept: item.concept, bucket: item.bucket, kind: item.kind, term: item.term,
                          label: item.label, evidence: newest_first(evidence), came_up_on: [ @set_date.iso8601 ],
                          expires_on: LearnerItem.expiry_for(newest_evidence_on: newest_date(evidence), created_on: @today),
                          returned_after: returned_after)
    end
    @written += 1
  rescue ActiveRecord::RecordNotUnique
    absorb(LearnerItem.open_by_key(@owner).fetch(key_of(item)), item)
  end

  def closed_rows(item)
    @owner.learner_items.where(concept: item.concept, bucket: item.bucket, kind: item.kind).where.not(status: "open")
          .select { |row| row.matching_key == key_of(item) }
  end

  # The label paraphrases the oldest day's note or explanation, so those stay for forget_citing! to find; the rest go newest first.
  def kept_evidence(evidence)
    ordered = newest_first(evidence)
    oldest_on = ordered.map { |reference| Date.iso8601(reference["date"]) }.min
    pinned = ordered.select { |reference| label_source?(reference, oldest_on) }
    newest_first(pinned + (ordered - pinned).first(LearnerItem::MAX_EVIDENCE - pinned.size))
  end

  def label_source?(reference, oldest_on)
    LearnerItem::WRITTEN_SOURCES.include?(reference["source"]) && Date.iso8601(reference["date"]) == oldest_on
  end

  def newest_first(evidence)
    evidence.uniq.each_with_index.sort_by { |reference, index| [ -Date.iso8601(reference["date"]).jd, index ] }.map(&:first)
  end

  def newest_date(evidence) = evidence.map { |reference| Date.iso8601(reference["date"]) }.max
end
