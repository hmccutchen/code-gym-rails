require "rails_helper"

RSpec.describe "Mastery reconciliation on PostgreSQL", type: :model do
  self.use_transactional_tests = false

  let!(:user) { User.create!(email: "mastery-726-#{SecureRandom.hex(8)}@example.com") }
  let!(:exercise) { user.daily_exercises.create!(date: Date.current, generated_at: Time.current, language: "ruby_rails", problem_set: { "pattern" => {} }) }
  let!(:response) { user.daily_responses.create!(daily_exercise: exercise, date: exercise.date) }

  after { user.destroy! }

  before do
    @initiation = {}
    allow(ConceptMastery).to receive(:record_review!).and_wrap_original do |method, target, **options|
      method.call(target, **options, initiate: @initiation.fetch(target.id, false))
    end
  end

  def submitted_day(date, keys: %w[pattern], concept: "n_plus_one")
    set = user.daily_exercises.create!(date: date, generated_at: Time.current, language: "ruby_rails",
      problem_set: keys.index_with { { "concept" => concept } })
    user.daily_responses.create!(date: date, daily_exercise: set, submitted_at: Time.current,
      answers: keys.index_with { "An answer" }, concept_tags: keys.index_with { concept },
      section_ratings: keys.index_with { "right_level" })
  end

  def review_day(id, grades, &before_store)
    target = DailyResponse.find(id)
    reviewer = Object.new
    reviewer.define_singleton_method(:review_sections) do |*_args, sections:|
      before_store&.call
      sections.index_with do |key|
        grades.key?(key) ? { ok: true, review: { "rating" => grades.fetch(key) } } : { ok: false, failure: "outage", provider: "anthropic" }
      end
    end
    ResponseReview.new(target, user: User.find(target.user_id), reviewer: reviewer).call
  end

  def connection_thread(&block)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection.execute("SET lock_timeout = '5s'")
        block.call
      ensure
        connection.execute("RESET lock_timeout")
      end
    end
  end

  def wait_for(queue) = Timeout.timeout(10) { queue.pop }

  it "serializes a Stop before a returning correction without holding locks during the provider call" do
    target = submitted_day(Date.current + 1, keys: %w[code_review pattern])
    @initiation[target.id] = true
    ConceptDrills.start!(user, concept: "n_plus_one", bucket: "ruby_rails")
    review_day(target.id, "pattern" => "strong")
    entered, release = Queue.new, Queue.new
    thread = connection_thread { review_day(target.id, "code_review" => "developing") { entered << true; wait_for(release) } }
    wait_for(entered)
    ConceptDrills.stop!(User.find(user.id), concept: "n_plus_one", bucket: "ruby_rails")
    release << true
    expect(thread.value.status).to eq(:ready)
    expect(user.concept_masteries.find_by!(concept: "n_plus_one").drilled_at).to be_nil
  ensure
    release << true if release
    thread&.join
  end

  it "serializes two different first-assessed responses without lost ticks or duplicate mastery rows" do
    paused = user.concept_masteries.create!(concept: "memoization", language: "ruby_rails", tier: :paused, cooldown_remaining: 2)
    targets = [ 1, 2 ].map { |offset| submitted_day(Date.current + offset) }
    targets.each { |target| @initiation[target.id] = true }
    entered, release = Queue.new, Queue.new
    threads = targets.map do |target|
      connection_thread { review_day(target.id, "pattern" => "strong") { entered << true; wait_for(release) } }
    end
    targets.size.times { wait_for(entered) }
    targets.size.times { release << true }
    expect(threads.map { |thread| thread.value.status }).to eq([ :ready, :ready ])
    expect(paused.reload).to have_attributes(tier: "reduced", cooldown_remaining: 0)
    expect(user.concept_masteries.where(concept: "n_plus_one").count).to eq(1)
  ensure
    threads&.size&.times { release << true }
    threads&.each(&:join)
  end

  it "discards a result after a different connection takes its stale claim" do
    target = submitted_day(Date.current + 1)
    @initiation[target.id] = true
    entered, release = Queue.new, Queue.new
    thread = connection_thread { review_day(target.id, "pattern" => "strong") { entered << true; wait_for(release) } }
    wait_for(entered)
    DailyResponse.where(id: target.id).update_all(reviewing_since: (DailyResponse::REVIEW_CLAIM_STALE_AFTER + 1.minute).ago)
    takeover = target.reload.claim_reviewing!
    release << true
    expect(thread.value.status).to eq(:busy)
    expect(target.reload).to have_attributes(ai_review: nil, mastery_application: {}, reviewing_since: takeover)
    expect(user.concept_masteries).to be_empty
  ensure
    release << true if release
    thread&.join
  end

  it "chooses reconciliation after locking even when the default-off provider started before enrollment" do
    stub_const("PracticePolicyMode::INITIATE_PRACTICE_POLICY", false)
    target = submitted_day(Date.current + 1, keys: %w[code_review pattern])
    later = submitted_day(Date.current + 2, concept: "caching")
    @initiation[target.id] = true
    mastery = user.concept_masteries.create!(concept: "n_plus_one", language: "ruby_rails",
      tier: :reduced, streak: 1, last_rating: "developing")
    entered, release = Queue.new, Queue.new
    thread = connection_thread do
      ApplicationRecord.cache do
        review_day(later.id, "pattern" => "strong") do
          expect(User.find(user.id).daily_responses.where.not(mastery_application: {}).exists?).to be(false)
          entered << true
          wait_for(release)
        end
      end
    end
    wait_for(entered)
    locking = Queue.new
    allow(User).to receive(:lock).and_wrap_original do |method, *args|
      locking << true if Thread.current == thread
      method.call(*args)
    end
    User.transaction do
      User.lock.find(user.id)
      review_day(target.id, "pattern" => "strong")
      release << true
      wait_for(locking)
    end
    expect(thread.value.status).to eq(:ready)
    @initiation[target.id] = false
    review_day(target.id, "code_review" => "developing")
    expect(mastery.reload).to have_attributes(tier: "paused", cooldown_remaining: 1)
    expect(later.reload.mastery_application["session_counted"]).to be(true)
  ensure
    release << true if release
    thread&.join
  end

  it "keeps a default-off result committed before enrollment in the legacy baseline" do
    stub_const("PracticePolicyMode::INITIATE_PRACTICE_POLICY", false)
    legacy = submitted_day(Date.current + 1, keys: %w[code_review pattern])
    enrolling = submitted_day(Date.current + 2, concept: "caching")
    @initiation[enrolling.id] = true
    paused = user.concept_masteries.create!(concept: "memoization", language: "ruby_rails", tier: :paused, cooldown_remaining: 2)
    entered, release = Queue.new, Queue.new
    thread = connection_thread { review_day(enrolling.id, "pattern" => "strong") { entered << true; wait_for(release) } }
    wait_for(entered)
    review_day(legacy.id, "pattern" => "strong")
    expect(legacy.reload.mastery_application).to eq({})
    release << true
    expect(thread.value.status).to eq(:ready)
    review_day(legacy.id, "code_review" => "developing")
    expect(legacy.reload.mastery_application["legacy_sections"]).to eq(%w[pattern])
    expect(user.concept_masteries.find_by!(concept: "n_plus_one")).to have_attributes(last_rating: "developing", streak: 1)
    expect(paused.reload).to have_attributes(tier: "reduced", cooldown_remaining: 0)
  ensure
    release << true if release
    thread&.join
  end

  it "rolls back a response and two mastery rows together" do
    rows = %w[n_plus_one memoization].map { |concept| user.concept_masteries.create!(concept: concept, language: "ruby_rails") }
    expect do
      ApplicationRecord.transaction do
        User.lock.find(user.id)
        response.lock!
        response.update!(mastery_application: { "version" => 1 })
        rows.each { |row| row.update!(streak: 2, review_reconciliation: { "version" => 1 }) }
        raise "abort owned transaction"
      end
    end.to raise_error("abort owned transaction")
    expect(response.reload.mastery_application).to eq({})
    rows.each { |row| expect(row.reload).to have_attributes(streak: 0, review_reconciliation: {}) }
  end

  it "round trips enum, dates and microseconds with replacement JSON assignments" do
    stamp = Time.iso8601("2026-11-01T05:30:00.123456Z")
    row = user.concept_masteries.create!(concept: "n_plus_one", language: "ruby_rails", tier: :reduced,
      drilled_at: stamp, next_retention_check_on: Date.new(2026, 11, 5))
    snapshot = row.attributes.slice("tier", "drilled_at", "next_retention_check_on")
    snapshot["drilled_at"] = row.drilled_at.utc.iso8601(6)
    snapshot["next_retention_check_on"] = row.next_retention_check_on.iso8601
    row.update!(review_reconciliation: { "baseline" => snapshot })
    expect(row.reload.review_reconciliation["baseline"]).to eq(
      "tier" => "reduced", "drilled_at" => "2026-11-01T05:30:00.123456Z", "next_retention_check_on" => "2026-11-05")
    row.update!(review_reconciliation: {})
    expect(row.reload.review_reconciliation).to eq({})
    expect(row.drilled_at).to eq(stamp)
  end

  it "locks and refreshes the response before merging unsaved review changes" do
    stale = DailyResponse.find(response.id)
    response.update!(ai_review: { "pattern" => { "rating" => "solid" } })
    ApplicationRecord.transaction do
      User.lock.find(user.id)
      stale.lock!
      expect(stale.ai_review).to eq(response.ai_review)
      stale.ai_review = stale.ai_review.merge("code_review" => { "rating" => "strong" })
      expect { stale.lock! }.to raise_error(RuntimeError, /unpersisted changes/)
      stale.save!
    end
    expect(response.reload.ai_review.keys).to contain_exactly("pattern", "code_review")
  end
end
