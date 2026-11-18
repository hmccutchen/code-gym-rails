class LearnerItem::Merge
  Result = Data.define(:written, :absorbed, :dropped)

  def self.call(user, items, set_date:)
    LearnerItem.transaction do
      owner = User.lock.find_by(id: user.id)
      next :deleted if owner.nil? || owner.anonymized?

      new(owner, set_date).run(items)
    end
  end

  def initialize(owner, set_date)
    @owner = owner
    @set_date = set_date
    @today = Time.current.in_time_zone(owner.effective_time_zone).to_date
    @written = 0
    @absorbed = 0
    @dropped = Hash.new(0)
  end

  def run(items)
    LearnerItem.expire_overdue!(@owner, today: @today)
    open = LearnerItem.open_by_key(@owner)
    repeats, fresh = collapse(items).partition { |item| open.key?(key_of(item)) }
    repeats.each { |item| absorb(open.fetch(key_of(item)), item) }
    @dropped[:over_limit] += fresh.size - LearnerItem::MAX_NEW_PER_DAY if fresh.size > LearnerItem::MAX_NEW_PER_DAY
    fresh.first(LearnerItem::MAX_NEW_PER_DAY).each { |item| insert(item) }
    LearnerItem.displace_past_limit!(@owner, today: @today)
    Result.new(written: @written, absorbed: @absorbed, dropped: @dropped.to_h)
  end

  private

  def key_of(item) = LearnerItem.matching_key(concept: item.concept, bucket: item.bucket, kind: item.kind, term: item.term)

  def collapse(items)
    items.group_by { |item| key_of(item) }.values.map do |same|
      same.first.with(evidence: same.flat_map(&:evidence).uniq)
    end
  end

  def absorb(row, item)
    evidence = newest_first(item.evidence + row.evidence).first(LearnerItem::MAX_EVIDENCE)
    created_on = row.created_at.in_time_zone(@owner.effective_time_zone).to_date
    row.update!(evidence: evidence, came_up_on: ([ @set_date.iso8601 ] | row.came_up_on).sort.reverse.first(LearnerItem::MAX_CAME_UP_ON),
                expires_on: LearnerItem.expiry_for(newest_evidence_on: newest_date(evidence), created_on: created_on))
    @absorbed += 1
  end

  def insert(item)
    closed = closed_rows(item)
    evidence = evidence_past_recent_use(item, closed)
    return @dropped[:recently_used] += 1 if evidence.empty?

    write(item, evidence.first(LearnerItem::MAX_EVIDENCE),
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

  def newest_first(evidence)
    evidence.uniq.each_with_index.sort_by { |reference, index| [ -Date.iso8601(reference["date"]).jd, index ] }.map(&:first)
  end

  def newest_date(evidence) = evidence.map { |reference| Date.iso8601(reference["date"]) }.max
end
