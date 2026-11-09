require "rails_helper"

RSpec.describe "Protected-practice writers", type: :model do
  let(:user) { create_user_with_key }

  def day(offset, eased: true, keys: %w[pattern code_review], concept: "memoization")
    exercise = user.daily_exercises.create!(date: Date.current + offset, generated_at: Time.current, language: "ruby_rails",
      problem_set: keys.index_with { { "concept" => concept, "eased" => eased } })
    user.daily_responses.create!(daily_exercise: exercise, date: exercise.date, submitted_at: Time.current,
      answers: keys.index_with { "An answer with reasoning." }, section_ratings: keys.index_with { "right_level" },
      concept_tags: keys.index_with { concept })
  end

  def review(response, grades)
    reviewer = Object.new
    reviewer.define_singleton_method(:review_sections) do |*_args, sections:|
      sections.index_with do |key|
        grades.key?(key) ? { ok: true, review: { "rating" => grades.fetch(key) } } :
          { ok: false, failure: "outage", provider: "anthropic" }
      end
    end
    ResponseReview.new(response.reload, user: user, reviewer: reviewer).call
  end

  it "enrolls an eased review by default and preserves its original request through rollback and manual commands" do
    clock = Time.iso8601("2026-11-02T12:34:56.123456Z")
    response = nil
    travel_to(clock, with_usec: true) do
      response = day(0, keys: %w[pattern])
      expect(review(response, "pattern" => "solid").status).to eq(:ready)
    end
    row = user.concept_masteries.find_by!(concept: "memoization", language: "ruby_rails")
    request = { "pattern" => { "mode" => "normal_retry", "source_response_id" => response.id, "requested_at" => clock.iso8601(6) } }
    expect(response.reload.mastery_application).to include("version" => 2, "policy" => 2)
    expect(row).to have_attributes(practice_requests: request, mastered_at: nil, review_reconciliation: {})
    stub_const("PracticePolicyMode::INITIATE_PRACTICE_POLICY", false)
    travel_to(clock + 1.day, with_usec: true) do
      ConceptDrills.start!(user, concept: row.concept, bucket: row.language)
      ConceptDrills.stop!(user, concept: row.concept, bucket: row.language)
      expect(row.reload.practice_requests).to eq(request)
      normal = day(0, eased: false, keys: %w[pattern])
      expect(review(normal, "pattern" => "solid").status).to eq(:ready)
      expect(normal.reload.mastery_application).to include("version" => 2, "policy" => 2)
      expect(row.reload).to have_attributes(practice_requests: {}, mastered_at: clock + 1.day)
    end
    expect(response.reload.mastery_application).to include("version" => 2, "policy" => 2)
    expect(PracticePolicyMode.active?(user)).to be(true)
  end

  it "replays a same-concept late v1 correction before normal v2 earning and later Stop/Start across DST" do
        stub_const("PracticePolicyMode::INITIATE_PRACTICE_POLICY", false)
        user.update!(time_zone: "America/New_York")
        d_clock = Time.iso8601("2026-11-01T03:59:59.123456Z")
        e_clock = Time.iso8601("2026-11-01T06:30:01.654321Z")
        start_clock = Time.iso8601("2026-11-03T05:00:00.456789Z")
        row = user.concept_masteries.create!(concept: "memoization", language: "ruby_rails", last_rating: "solid")
        d = e = nil
        Time.use_zone(user.effective_time_zone) do
          travel_to(d_clock, with_usec: true) do
            ConceptDrills.start!(user, concept: row.concept, bucket: row.language)
            d = day(0)
            expect(review(d, "pattern" => "solid").status).to eq(:partial)
          end
          original = row.reload.review_reconciliation.fetch("operations").first
          expect(original).to include("occurred_at" => d_clock.iso8601(6), "reviewed_on" => "2026-10-31", "work_on" => "2026-10-31")
          expect(ConceptDrills.for(user).reserved?(row.concept, row.language)).to be(true)
          stub_const("PracticePolicyMode::INITIATE_PRACTICE_POLICY", true)
          travel_to(e_clock, with_usec: true) do
            e = day(0, eased: false, keys: %w[pattern])
            expect(review(e, "pattern" => "solid").status).to eq(:ready)
          end
          stub_const("PracticePolicyMode::INITIATE_PRACTICE_POLICY", false)
          expect(row.reload.review_reconciliation.fetch("operations").select { |event| event["type"] == "review" })
            .to match([ include("response_id" => d.id, "policy" => 1, "occurred_at" => d_clock.iso8601(6)),
              include("response_id" => e.id, "policy" => 2, "occurred_at" => e_clock.iso8601(6), "reviewed_on" => "2026-11-01") ])
          travel_to(start_clock - 1.day, with_usec: true) { ConceptDrills.stop!(user, concept: row.concept, bucket: row.language) }
          travel_to(start_clock, with_usec: true) { ConceptDrills.start!(user, concept: row.concept, bucket: row.language) }
          travel_to(start_clock + 1.day, with_usec: true) { expect(review(d, "code_review" => "beginner").status).to eq(:ready) }
        end
        expected = { "tier" => "standard", "streak" => 0, "last_rating" => "solid", "cooldown_remaining" => 0,
          "mastered_at" => e_clock.iso8601(6), "retention_interval_days" => 7, "next_retention_check_on" => "2026-11-08",
          "drilled_at" => start_clock.iso8601(6), "drill_group" => nil, "practice_requests" => {} }
        expect(ConceptMastery::Reconciliation.snapshot(row.reload)).to eq(expected)
        expect(row.review_reconciliation).to eq({})
        expect(d.reload.mastery_application).to eq("version" => 1, "legacy_sections" => [], "processed_sections" => %w[pattern code_review],
          "session_counted" => true, "skip_attempts" => [])
        expect(e.reload.mastery_application).to eq("version" => 2, "policy" => 2, "legacy_sections" => [], "processed_sections" => %w[pattern],
          "session_counted" => true, "skip_attempts" => [])
        drills = ConceptDrills.for(user)
        expect(drills.count).to eq(1)
        expect(drills.reserved?(row.concept, row.language)).to be(false)
        expect(drills.drilling?(row.concept, row.language)).to be(true)
        expect(review(d, {}).status).to eq(:already_reviewed)
        expect(review(e, {}).status).to eq(:already_reviewed)
        expect(ConceptMastery::Reconciliation.snapshot(row.reload)).to eq(expected)
        expect(PracticePolicyMode.active?(user)).to be(true)
      end

      it "rolls back v2 requests, session ticks, open suffixes and the final response after successful mastery writes" do
        open_response = day(-1)
        review(open_response, "pattern" => "solid")
        retry_row = user.concept_masteries.find_by!(concept: "memoization")
        other = user.concept_masteries.create!(concept: "n_plus_one", language: "ruby_rails")
        paused = user.concept_masteries.create!(concept: "service_objects", language: "ruby_rails", tier: :paused, cooldown_remaining: 2)
        target = day(0)
        target.update!(concept_tags: { "pattern" => "memoization", "code_review" => "n_plus_one" },
          review_errors: { "pattern" => { "kind" => "outage" } })
        original_rows = [ retry_row, other, paused ].to_h { |row| [ row.id, row.reload.attributes ] }
        original_response = target.attributes.slice("ai_review", "mastery_application", "review_errors", "review_provider", "reviewing_since")
        original_receipt = open_response.reload.mastery_application
        allow(target).to receive(:save!) do
          expect(paused.reload.cooldown_remaining).to eq(1)
          expect(other.reload.practice_requests).to include("code_review" => include("mode" => "normal_retry"))
          expect(retry_row.reload.review_reconciliation.fetch("operations").size)
            .to be > original_rows.fetch(retry_row.id).fetch("review_reconciliation").fetch("operations").size
          raise ActiveRecord::RecordInvalid, target
        end
        expect { review(target, "pattern" => "solid", "code_review" => "solid") }.to raise_error(ActiveRecord::RecordInvalid)
        expect([ retry_row, other, paused ].to_h { |row| [ row.id, row.reload.attributes ] }).to eq(original_rows)
        expect(target.reload.attributes.slice(*original_response.keys)).to eq(original_response)
        expect(open_response.reload.mastery_application).to eq(original_receipt)
      end

  it "keeps an existing v1 response policy while new enrolled responses use v2 with initiation off" do
    stub_const("PracticePolicyMode::INITIATE_PRACTICE_POLICY", false)
    legacy = day(0)
    review(legacy, "pattern" => "solid")
    expect(legacy.reload.mastery_application["version"]).to eq(1)
    enrolling = day(1, keys: %w[pattern], concept: "n_plus_one")
    stub_const("PracticePolicyMode::INITIATE_PRACTICE_POLICY", true)
    review(enrolling, "pattern" => "solid")
    stub_const("PracticePolicyMode::INITIATE_PRACTICE_POLICY", false)
    review(legacy, "code_review" => "solid")
    expect(legacy.reload.mastery_application["version"]).to eq(1)
    expect(user.concept_masteries.find_by!(concept: "memoization").retention_interval_days).to eq(7)
    newer = day(2, keys: %w[pattern], concept: "service_objects")
    review(newer, "pattern" => "solid")
    expect(newer.reload.mastery_application).to include("version" => 2, "policy" => 2)
    expect(user.concept_masteries.find_by!(concept: "service_objects")).to have_attributes(
      mastered_at: nil, practice_requests: include("pattern" => include("mode" => "normal_retry")))
  end

  it "does not reinterpret pre-receipt legacy keys when an outstanding sibling starts v2" do
    response = day(0)
    response.update!(ai_review: { "pattern" => { "rating" => "solid" } })
    user.concept_masteries.create!(concept: "memoization", language: "ruby_rails",
      mastered_at: 1.day.ago, retention_interval_days: 7, next_retention_check_on: Date.current + 6)
    review(response, "code_review" => "solid")
    expect(response.reload.mastery_application["legacy_sections"]).to eq(%w[pattern])
    expect(user.concept_masteries.find_by!(concept: "memoization").practice_requests.keys).to eq(%w[code_review])
  end

  it "preserves requests through single/group Stop and Start and keeps eased drilling admitted" do
    response = day(0, keys: %w[pattern], concept: "shallow_module")
    ConceptDrills.start!(user, concept: "shallow_module", bucket: "ruby_rails")
    review(response, "pattern" => "solid")
    row = user.concept_masteries.find_by!(concept: "shallow_module")
    pending = row.practice_requests.deep_dup
    stamp = row.drilled_at
    expect(ConceptDrills.for(user).count).to eq(1)
    expect(ConceptDrills.start!(user, concept: row.concept, bucket: row.language)).to be(false)
    expect(row.reload.drilled_at).to eq(stamp)
    ConceptDrills.stop!(user, concept: row.concept, bucket: row.language)
    ConceptDrills.start!(user, concept: row.concept, bucket: row.language)
    expect(row.reload.practice_requests).to eq(pending)
    group = ConceptGroup.for(row.concept)
    ConceptDrills.start_group!(user, group: group, bucket: row.language)
    ConceptDrills.stop_group!(user, group: group, bucket: row.language)
    expect(row.reload.practice_requests).to eq(pending)
    ConceptDrills.start_group!(user, group: group, bucket: row.language)
    expect(row.reload.practice_requests).to eq(pending)
    normal = day(1, eased: false, keys: %w[pattern], concept: row.concept)
    review(normal, "pattern" => "strong")
    expect(row.reload).to have_attributes(practice_requests: {}, drilled_at: nil)
  end

  it "rejects corrupt durable state before committing response or mastery changes" do
    response = day(0, keys: %w[pattern])
    corrupt = user.concept_masteries.create!(concept: "n_plus_one", language: "ruby_rails", practice_requests: [])
    expect { review(response, "pattern" => "solid") }.to raise_error(ArgumentError)
    expect(response.reload.ai_review).to be_nil
    expect(response.mastery_application).to eq({})
    expect(user.concept_masteries.pluck(:id)).to eq([ corrupt.id ])
  end
end
