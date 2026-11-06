require "rails_helper"

RSpec.describe ResponseReview do
  include AuthHelpers

  let(:user) { create_user_with_key }
  let(:exercise) do
    DailyExercise.create!(user: user, date: Date.current, generated_at: Time.current, language: "ruby_rails",
                          problem_set: { "code_review" => { "concept" => "n_plus_one", "question" => "q", "snippet" => "s" },
                                         "pattern" => { "concept" => "memoization", "question" => "q" } })
  end
  let(:response) do
    DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current, submitted_at: Time.current,
                          answers: { "code_review" => "a" * 20, "pattern" => "b" * 20 },
                          section_ratings: { "code_review" => "right_level", "pattern" => "right_level" })
  end
  let(:reviewer) { instance_double(ClaudeService) }

  def review_result(rating) = { ok: true, review: { "rating" => rating } }
  def failed_result = { ok: false, failure: "outage", provider: "anthropic" }

  def review(subject_response = response)
    described_class.new(subject_response, user: user, reviewer: reviewer).call
  end

  describe "daily mastery reconciliation" do
    before { stub_const("ConceptMastery::INITIATE_RECONCILIATION", true) }

    around do |example|
      Time.use_zone("America/New_York") do
        travel_to(Time.zone.local(2026, 11, 5, 12)) { example.run }
      end
    end

    let(:exercise) do
      user.daily_exercises.create!(date: Date.current, generated_at: Time.current, language: "ruby_rails",
        problem_set: %w[code_review pattern].index_with { { "concept" => "n_plus_one", "question" => "Find the repeated query." } })
    end
    let(:response) do
      user.daily_responses.create!(daily_exercise: exercise, date: exercise.date, submitted_at: Time.current,
        answers: %w[code_review pattern].index_with { "Preload the records." },
        section_ratings: %w[code_review pattern].index_with { "right_level" },
        concept_tags: %w[code_review pattern].index_with { "n_plus_one" })
    end
    let!(:mastery) do
      user.concept_masteries.create!(concept: "n_plus_one", language: "ruby_rails", tier: :standard,
        streak: 2, last_rating: "developing", drilled_at: 1.day.ago, mastered_at: 30.days.ago,
        retention_interval_days: 7, next_retention_check_on: Date.current)
    end
    let!(:paused) do
      user.concept_masteries.create!(concept: "memoization", language: "ruby_rails", tier: :paused, cooldown_remaining: 2)
    end

    def batch(target, grades = nil, initiate: true, **ratings)
      grades ||= ratings
      allow(ConceptMastery).to receive(:record_review!).and_wrap_original do |method, *args, **kwargs|
        method.call(*args, **kwargs, initiate: initiate)
      end
      allow(reviewer).to receive(:review_sections) do |*_args, sections:|
        sections.index_with { |key| grades.key?(key) ? review_result(grades.fetch(key)) : failed_result }
      end
      described_class.new(target, user: target.user, reviewer: reviewer).call
    end

    def another_day(offset, concept: "caching", answer: "An answer", keys: %w[pattern], owner: user)
      date = response.date + offset
      exercise = owner.daily_exercises.create!(date: date, generated_at: Time.current, language: "ruby_rails",
        problem_set: keys.index_with { { "concept" => concept } })
      owner.daily_responses.create!(date: date, daily_exercise: exercise, submitted_at: Time.current,
        answers: keys.index_with { answer }, concept_tags: keys.index_with { concept },
        section_ratings: keys.index_with { "right_level" })
    end

    def domain(row) = ConceptMastery::Reconciliation.snapshot(row.reload)

    [ :two_sessions, :later_review, :skipped_day, :start, :stop_restart ].each do |interleaving|
      it "matches a full-at-first-commit control across all nine fields after #{interleaving}" do
        mastery.update!(tier: :reduced, streak: 1)
        control = User.create!(email: "control-726@example.com", time_zone: user.time_zone)
        control_mastery = control.concept_masteries.create!(concept: mastery.concept, language: mastery.language,
          **mastery.attributes.slice(*ConceptMastery::Transition::FIELDS))
        control_response = another_day(0, concept: "n_plus_one", keys: %w[code_review pattern], owner: control)
        batch(response, "pattern" => "strong")
        batch(control_response, "pattern" => "strong", "code_review" => "developing")
        travel 1.day
        [ user, control ].each do |owner|
          case interleaving
          when :two_sessions
            [ 1, 2 ].each { |offset| batch(another_day(offset, owner: owner), "pattern" => "strong") }
          when :later_review
            batch(another_day(1, owner: owner, concept: "n_plus_one"), "pattern" => "strong")
          when :skipped_day
            batch(another_day(1, owner: owner, concept: "n_plus_one", answer: ""), "pattern" => nil)
          when :start
            ConceptDrills.stop!(owner, concept: "n_plus_one", bucket: "ruby_rails")
            ConceptDrills.start!(owner, concept: "n_plus_one", bucket: "ruby_rails")
          when :stop_restart
            ConceptDrills.stop!(owner, concept: "n_plus_one", bucket: "ruby_rails")
            ConceptDrills.start!(owner, concept: "n_plus_one", bucket: "ruby_rails")
            ConceptDrills.stop!(owner, concept: "n_plus_one", bucket: "ruby_rails")
          end
        end
        travel 1.day
        batch(response, "code_review" => "developing")
        expect(domain(mastery)).to eq(domain(control_mastery))
      end
    end

    [ %w[pattern code_review], %w[code_review pattern] ].each do |order|
      [ nil, "too_hard" ].each do |self_rating|
        it "aggregates favourable grades with #{self_rating.inspect} effort in #{order.inspect} order" do
          response.update!(section_ratings: { "pattern" => self_rating, "code_review" => "right_level" })
          order.each { |key| batch(response, key => "strong") }
          expect(mastery.reload).to have_attributes(last_rating: "strong", streak: 0, tier: "standard",
            retention_interval_days: nil, next_retention_check_on: nil)
          expect(mastery.drilled_at).to be_present
        end
      end
    end

    it "does not prioritize a reserved drill in planning or reinforcement" do
      batch(response, "pattern" => "strong")
      expect(ConceptDrills.for(user).reserved?("n_plus_one", "ruby_rails")).to be(true)
      expect(user.concept_masteries.drilling.where(concept: "n_plus_one")).to be_empty
      expect(user.concepts_needing_reinforcement.map { |entry| entry[:concept] }).not_to include("n_plus_one")
      expect(user.concept_masteries.due_for_retention_check.where(concept: "n_plus_one")).to be_empty
    end

    it "keeps an untouched default-off user on batch semantics without receipts or suffixes" do
      batch(response, { "pattern" => "strong" }, initiate: false)
      batch(response, { "code_review" => "developing" }, initiate: false)
      expect(response.reload.mastery_application).to eq({})
      expect(mastery.reload.review_reconciliation).to eq({})
      expect(mastery).to have_attributes(tier: "standard", streak: 1, drilled_at: nil)
    end

    it "records an unrelated default-off session in the whole user's open correction suffix" do
      mastery.update!(tier: :reduced, streak: 1)
      batch(response, "pattern" => "strong")
      [ 1, 2 ].each do |offset|
        later = another_day(offset)
        batch(later, { "pattern" => "strong" }, initiate: false)
      end
      expect(mastery.reload.review_reconciliation["operations"].map { |op| op["type"] }).to eq(%w[review session session])
      batch(response, { "code_review" => "developing" }, initiate: false)
      expect(mastery.reload).to have_attributes(tier: "reduced", streak: 0, cooldown_remaining: 0, last_rating: "developing")
    end

    it "keeps enrollment through compaction and starts a new suffix with initiation off" do
      batch(response, "pattern" => "strong", "code_review" => "strong")
      expect(mastery.reload.review_reconciliation).to eq({})
      later = another_day(1, concept: "n_plus_one", keys: %w[code_review pattern])
      batch(later, { "pattern" => "strong" }, initiate: false)
      expect(later.reload.mastery_application["processed_sections"]).to eq(%w[pattern])
      expect(mastery.reload.review_reconciliation["operations"].first["response_id"]).to eq(later.id)
    end

    [ :newest_first, :oldest_first ].each do |order|
      it "closes two persisted open contributions #{order} without losing the earlier correction" do
        original_drill = mastery.drilled_at
        batch(response, "pattern" => "strong")
        later = another_day(1, concept: "n_plus_one", keys: %w[code_review pattern])
        travel 1.day
        batch(later, "pattern" => "strong")
        targets = order == :newest_first ? [ later, response ] : [ response, later ]
        batch(targets.first, "code_review" => "developing")
        reviews = mastery.reload.review_reconciliation["operations"].select { |operation| operation["type"] == "review" }
        expect(reviews.size).to eq(order == :newest_first ? 2 : 1)
        batch(targets.last, "code_review" => "developing")
        expect(mastery.reload).to have_attributes(tier: "reduced", streak: 1, last_rating: "developing",
          drilled_at: original_drill, retention_interval_days: nil, next_retention_check_on: nil, review_reconciliation: {})
        expect(targets.map { |target| target.reload.mastery_application["processed_sections"].sort })
          .to eq([ %w[code_review pattern], %w[code_review pattern] ])
      end
    end

    it "uses a suffix even if its response receipt is missing" do
      batch(response, "pattern" => "strong")
      response.update!(mastery_application: {})
      later = another_day(1)
      batch(later, { "pattern" => "strong" }, initiate: false)
      expect(mastery.reload.review_reconciliation["operations"].last).to eq("type" => "session", "response_id" => later.id)
    end

    it "locks user before response and existing mastery rows in ascending order" do
      statements = []
      subscriber = ->(_name, _start, _finish, _id, payload) { statements << payload[:sql] if payload[:sql].include?("FOR UPDATE") }
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { batch(response, "pattern" => "strong") }
      expect(statements[0]).to include('FROM "users"')
      expect(statements[1]).to include('FROM "daily_responses"')
      expect(statements[2]).to include('FROM "concept_masteries"', 'ORDER BY "concept_masteries"."id" ASC')
    end

    it "keeps a durable receipt idempotent after a complete day and fresh reload" do
      batch(response, "pattern" => "strong", "code_review" => "strong")
      before = domain(mastery)
      fresh = DailyResponse.find(response.id)
      apply_mastery_review!(fresh, sections: %w[code_review pattern], apply_session_countdown: true,
        previous_review_keys: %w[code_review pattern], initiate: false)
      expect(domain(mastery)).to eq(before)
      expect(paused.reload.cooldown_remaining).to eq(1)
      expect(fresh.mastery_application["processed_sections"]).to contain_exactly("pattern", "code_review")
    end

    it "closes a pending invalid success without letting it grade or count another session" do
      batch(response, "pattern" => "strong")
      before = domain(mastery)
      batch(response, "code_review" => "off_list")
      expect(domain(mastery)).to eq(before)
      expect(mastery.review_reconciliation).to eq({})
      expect(response.reload.mastery_application["processed_sections"]).to contain_exactly("pattern", "code_review")
      expect(paused.reload.cooldown_remaining).to eq(1)
    end

    it "does not mark failed sections processed or enroll a wholly failed review" do
      batch(response, {})
      expect(response.reload.mastery_application).to eq({})
      batch(response, "pattern" => "strong")
      expect(response.reload.mastery_application["processed_sections"]).to eq(%w[pattern])
    end

    [ %w[code_review pattern], %w[pattern code_review] ].each do |order|
      it "keeps the first-core service and receipt guards for bug/core order #{order.inspect}" do
        exercise.update!(problem_set: exercise.problem_set.deep_merge("code_review" => { "purpose" => "Find the trap" }))
        batch(response, order.first => "strong")
        expect(paused.reload.cooldown_remaining).to eq(order.first == "pattern" ? 1 : 2)
        batch(response, { order.last => "strong" }, initiate: false)
        expect(paused.reload.cooldown_remaining).to eq(1)
        expect(response.reload.mastery_application["session_counted"]).to be(true)
      end
    end

    it "guards direct new-writer countdown against a successful supplementary-only subset" do
      exercise.update!(problem_set: exercise.problem_set.deep_merge("code_review" => { "purpose" => "Find the trap" }))
      response.ai_review = { "code_review" => { "rating" => "strong" }, "pattern" => { "rating" => "solid" } }
      apply_mastery_review!(response, sections: %w[code_review], previous_review_keys: [], apply_session_countdown: true, initiate: true)
      expect(paused.reload.cooldown_remaining).to eq(2)
      expect(response.reload.mastery_application["session_counted"]).to be(false)
    end

    it "leaves a fully reviewed legacy submission untouched without contacting a provider" do
      response.update!(ai_review: %w[code_review pattern].index_with { { "rating" => "strong" } })
      original = domain(mastery)
      expect(reviewer).not_to receive(:review_sections)
      expect(review.status).to eq(:already_reviewed)
      expect(response.reload.mastery_application).to eq({})
      expect(domain(mastery)).to eq(original)
    end

    it "takes a legacy partial as baseline without reapplying its keys or countdown" do
      batch(response, { "pattern" => "strong" }, initiate: false)
      batch(response, { "code_review" => "developing" }, initiate: true)
      expect(mastery.reload).to have_attributes(tier: "standard", streak: 1, last_rating: "developing", drilled_at: nil)
      expect(response.reload.mastery_application).to include("legacy_sections" => %w[pattern],
        "processed_sections" => %w[code_review], "session_counted" => true)
      expect(paused.reload.cooldown_remaining).to eq(1)
    end

    [ nil, "invalid" ].each do |grade|
      it "counts once after an unassessed legacy #{grade.inspect} prefix" do
        response.update!(ai_review: { "code_review" => { "rating" => grade } })
        batch(response, "pattern" => "strong")
        expect(paused.reload.cooldown_remaining).to eq(1)
        expect(response.reload.mastery_application["session_counted"]).to be(true)
      end
    end

    it "retains later same-concept evidence and its original date through a weak correction" do
      mastery.update!(streak: 1)
      batch(response, "pattern" => "strong")
      later = another_day(1, concept: "n_plus_one")
      travel 1.day
      batch(later, "pattern" => "strong")
      travel 4.days
      batch(response, "code_review" => "developing")
      expect(mastery.reload).to have_attributes(tier: "standard", last_rating: "strong",
        retention_interval_days: 7, next_retention_check_on: Date.new(2026, 11, 13))
    end

    it "uses the first local application date through a retry over midnight and DST" do
      travel_to Time.utc(2026, 11, 1, 5, 59, 59)
      mastery.update!(next_retention_check_on: Date.current)
      batch(response, "pattern" => "strong")
      original = domain(mastery)
      travel_to Time.utc(2026, 11, 2, 5, 1)
      batch(response, "code_review" => "strong")
      expect(domain(mastery)).to eq(original)
      expect(mastery.next_retention_check_on).to eq(Date.new(2026, 11, 15))
    end

    it "schedules an initial late review from its actual local review day" do
      response
      travel 4.days
      batch(response, "pattern" => "strong", "code_review" => "strong")
      expect(mastery.reload.next_retention_check_on).to eq(Date.current + 14)
    end

    it "keeps eased comfortable success on current retention policy" do
      mastery.update!(tier: :reduced)
      exercise.update!(problem_set: exercise.problem_set.transform_values { |entry| entry.merge("eased" => true) })
      batch(response, "pattern" => "strong", "code_review" => "strong")
      expect(mastery.reload).to have_attributes(tier: "standard", retention_interval_days: 14, next_retention_check_on: Date.current + 14)
    end

    it "retains one skipped attempt even if another batch and correction later make it relevant" do
      batch(response, "pattern" => "strong")
      skipped = another_day(20, concept: "n_plus_one", answer: "", keys: %w[code_review pattern])
      travel 20.days
      batch(skipped, "code_review" => nil)
      batch(skipped, "pattern" => nil)
      operations = mastery.reload.review_reconciliation["operations"]
      expect(operations.count { |op| op["type"] == "skip" }).to eq(1)
      expect(skipped.reload.mastery_application["skip_attempts"]).to eq([ %w[ruby_rails n_plus_one] ])
      batch(response, "code_review" => "developing")
      expect(mastery.reload.next_retention_check_on).to be_nil
    end

    it "re-evaluates an initially not-due skip after corrected pauses shorten the later schedule" do
      mastery.update!(tier: :reduced, streak: 1)
      batch(response, "pattern" => "strong")
      [ 1, 2 ].each do |offset|
        later = another_day(offset, concept: "n_plus_one")
        travel 1.day
        batch(later, "pattern" => "strong")
      end
      skipped = another_day(9, concept: "n_plus_one", answer: "", keys: %w[code_review pattern])
      travel 7.days
      original_due = mastery.reload.next_retention_check_on
      batch(skipped, "code_review" => nil)
      batch(skipped, "pattern" => nil)
      expect(mastery.reload.next_retention_check_on).to eq(original_due)
      expect(mastery.review_reconciliation["operations"].count { |operation| operation["type"] == "skip" }).to eq(1)
      batch(response, "code_review" => "developing")
      expect(mastery.reload).to have_attributes(tier: "standard", last_rating: "strong", retention_interval_days: 7,
        next_retention_check_on: response.date + 16, review_reconciliation: {})
    end

    it "rolls back both mastery rows and the receipt if saving the merged response fails" do
      original = domain(mastery)
      allow(response).to receive(:save!).and_raise(ActiveRecord::RecordInvalid.new(response))
      expect { batch(response, "pattern" => "strong") }.to raise_error(ActiveRecord::RecordInvalid)
      expect(domain(mastery)).to eq(original)
      expect(mastery.review_reconciliation).to eq({})
      expect(paused.reload.cooldown_remaining).to eq(2)
      expect(response.reload).to have_attributes(ai_review: nil, mastery_application: {}, reviewing_since: nil)
    end

    it "preserves a stolen claim and writes no receipt or suffix" do
      takeover = 1.second.from_now.floor(6)
      allow(reviewer).to receive(:review_sections) do
        response.update_columns(reviewing_since: takeover)
        { "pattern" => review_result("strong") }
      end
      expect(review.status).to eq(:busy)
      expect(response.reload).to have_attributes(mastery_application: {}, ai_review: nil, reviewing_since: takeover)
      expect(mastery.reload.review_reconciliation).to eq({})
      expect(paused.reload.cooldown_remaining).to eq(2)
    end

    [ nil, [], "text", false, 0, { "version" => 999 } ].each do |bad|
      it "rejects an invalid enrollment receipt from another response: #{bad.inspect}" do
        unrelated = another_day(1)
        quoted = DailyResponse.connection.quote(bad.to_json)
        DailyResponse.where(id: unrelated.id).update_all("mastery_application = #{quoted}::jsonb")
        expect { batch(response, { "pattern" => "strong" }, initiate: false) }.to raise_error(ArgumentError)
        expect(response.reload.mastery_application).to eq({})
        expect(paused.reload.cooldown_remaining).to eq(2)
      end

      %i[mastery_application review_reconciliation].each do |column|
        it "refuses stored #{column} #{bad.inspect} with initiation off" do
          record = column == :mastery_application ? response : mastery
          quoted = record.class.connection.quote(bad.to_json)
          record.class.where(id: record.id).update_all("#{column} = #{quoted}::jsonb")
          original = domain(mastery)
          expect { batch(response, { "pattern" => "strong" }, initiate: false) }.to raise_error(ArgumentError)
          expect(domain(mastery)).to eq(original)
          expect(paused.reload.cooldown_remaining).to eq(2)
          expect(response.reload.ai_review).to be_nil
        end
      end
    end

    [ [ %w[code_review pattern] ], [ %w[code_review], %w[pattern] ], [ %w[pattern], %w[code_review] ] ].each do |batches|
      it "reconciles one concept for batches #{batches.inspect}" do
        grades = { "code_review" => "developing", "pattern" => "strong" }
        original_drill = mastery.drilled_at
        original_mastery_time = mastery.mastered_at
        batch_index = 0
        allow(reviewer).to receive(:review_sections) do |*_args, sections:|
          successful = batches.fetch(batch_index)
          batch_index += 1
          sections.index_with { |key| successful.include?(key) ? review_result(grades.fetch(key)) : failed_result }
        end

        batches.each_with_index do |_, index|
          expect(review.status).to eq(index == batches.length - 1 ? :ready : :partial)
          expect(response.reload.reviewing_since).to be_nil
          expect(paused.reload.cooldown_remaining).to eq(1)
          next unless index.zero? && batches.length > 1

          expect(mastery.reload.last_rating).to eq(grades.fetch(batches.first.first))
          expect(response).not_to be_fully_reviewed
          if batches.first == %w[code_review]
            expect(mastery.tier).to eq("reduced")
          else
            expect(mastery.retention_interval_days).to eq(14)
            expect(mastery.drilled_at).to be_nil
          end
        end

        expect(mastery.reload).to have_attributes(tier: "reduced", streak: 0, last_rating: "developing",
          drilled_at: original_drill, retention_interval_days: nil, next_retention_check_on: nil,
          mastered_at: original_mastery_time)
        expect(response.ai_review.transform_values { |r| r["rating"] }).to eq(grades)
        expect(review.status).to eq(:already_reviewed)
        expect(paused.reload.cooldown_remaining).to eq(1)
      end
    end
  end

  [ %w[code_review pattern], %w[pattern code_review] ].each do |order|
    it "counts only the first core assessment with batches #{order.inspect}" do
      paused = user.concept_masteries.create!(concept: "caching", language: "ruby_rails", tier: :paused, cooldown_remaining: 2)
      exercise.update!(problem_set: exercise.problem_set.deep_merge("code_review" => { "purpose" => "Find the trap" }))
      allow(reviewer).to receive(:review_sections).and_return(
        { order.first => review_result("solid"), order.last => failed_result },
        { order.last => review_result("solid") }
      )
      review
      expect(paused.reload.cooldown_remaining).to eq(order.first == "pattern" ? 1 : 2)
      review
      expect(paused.reload.cooldown_remaining).to eq(1)
      review
      expect(paused.reload.cooldown_remaining).to eq(1)
    end

    it "counts the first core batch once with a later pending core answer and a bug in the same batch" do
      paused = user.concept_masteries.create!(concept: "caching", language: "ruby_rails", tier: :paused, cooldown_remaining: 2)
      exercise.update!(problem_set: exercise.problem_set.deep_merge("code_review" => { "purpose" => "Find the trap" })
        .merge("plan_review" => { "question" => "q" }))
      response.update!(answers: response.answers.merge("plan_review" => "answer"))
      allow(reviewer).to receive(:review_sections).and_return(
        { "code_review" => review_result("solid"), "pattern" => review_result("solid"), "plan_review" => failed_result },
        { "plan_review" => review_result("solid") })
      review
      expect(paused.reload.cooldown_remaining).to eq(1)
      review
      expect(paused.reload.cooldown_remaining).to eq(1)
      review
      expect(paused.reload.cooldown_remaining).to eq(1)
    end

    it "guards the mastery countdown boundary against a direct bug-only application" do
      paused = user.concept_masteries.create!(concept: "caching", language: "ruby_rails", tier: :paused, cooldown_remaining: 1)
      exercise.update!(problem_set: exercise.problem_set.deep_merge("code_review" => { "purpose" => "Find the trap" }))
      response.ai_review = { "code_review" => { "rating" => "strong" } }
      apply_mastery_review!(response, sections: [ "code_review" ], apply_session_countdown: true)
      expect(paused.reload).to have_attributes(tier: "paused", cooldown_remaining: 1)
    end
  end

  [ nil, "invalid" ].each do |grade|
    it "counts the first assessed answer after an earlier #{grade.inspect} batch exactly once" do
      paused = user.concept_masteries.create!(concept: "caching", language: "ruby_rails", tier: :paused, cooldown_remaining: 2)
      response.update!(answers: { "code_review" => (grade ? "x" : ""), "pattern" => "y" })
      allow(reviewer).to receive(:review_sections).and_return(
        { "code_review" => review_result(grade), "pattern" => failed_result },
        { "pattern" => review_result("solid") }
      )
      expect(review.status).to eq(:partial)
      expect(paused.reload.cooldown_remaining).to eq(2)
      expect(review.status).to eq(:ready)
      expect(paused.reload.cooldown_remaining).to eq(1)
      expect(review.status).to eq(:already_reviewed)
      expect(paused.reload.cooldown_remaining).to eq(1)
    end
  end

  it "reports a response that was never submitted, without calling the provider" do
    response.update!(submitted_at: nil)
    expect(reviewer).not_to receive(:review_sections)

    expect(review.status).to eq(:not_submitted)
  end

  it "reports a response with every section reviewed, without claiming it" do
    response.update!(ai_review: { "code_review" => { "rating" => "solid" }, "pattern" => { "rating" => "solid" } })
    expect(reviewer).not_to receive(:review_sections)

    expect(review.status).to eq(:already_reviewed)
    expect(response.reload.reviewing_since).to be_nil
  end

  it "backs off while another review holds a fresh claim" do
    response.update!(reviewing_since: Time.current)
    expect(reviewer).not_to receive(:review_sections)

    expect(review.status).to eq(:busy)
  end

  it "reviews only the sections still missing and stores every result" do
    response.update!(ai_review: { "code_review" => { "rating" => "solid" } })
    allow(reviewer).to receive(:review_sections).and_return("pattern" => review_result("strong"))

    outcome = review

    expect(reviewer).to have_received(:review_sections).with(user, exercise, response, sections: %w[pattern])
    expect(outcome.status).to eq(:ready)
    expect(response.reload.ai_review).to eq("code_review" => { "rating" => "solid" }, "pattern" => { "rating" => "strong" })
    expect(response.review_provider).to eq(user.provider)
    expect(response.reviewing_since).to be_nil
  end

  it "reports a partial review, stores the failures, and keeps the claim free for a retry" do
    allow(reviewer).to receive(:review_sections)
      .and_return("code_review" => review_result("solid"), "pattern" => failed_result)

    outcome = review

    expect(outcome.status).to eq(:partial)
    expect(outcome.successes.keys).to eq(%w[code_review])
    expect(outcome.failures.keys).to eq(%w[pattern])
    expect(outcome.missing).to eq(%w[code_review pattern])
    expect(response.reload.review_errors.dig("pattern", "kind")).to eq("outage")
    expect(response.reviewing_since).to be_nil
  end

  it "clears a section's stored failure once a retry reviews it" do
    response.update!(ai_review: { "code_review" => { "rating" => "solid" } },
                     review_errors: { "pattern" => { "kind" => "outage" } })
    allow(reviewer).to receive(:review_sections).and_return("pattern" => review_result("solid"))

    review

    expect(response.reload.review_errors).to eq({})
  end

  it "reports a review where every section failed, and writes no mastery" do
    allow(reviewer).to receive(:review_sections).and_return("code_review" => failed_result, "pattern" => failed_result)

    expect { expect(review.status).to eq(:failed) }.not_to change(ConceptMastery, :count)
  end

  it "records mastery for the reviewed sections, counting the session only on the first batch" do
    allow(reviewer).to receive(:review_sections)
      .and_return("code_review" => review_result("solid"), "pattern" => review_result("solid"))
    allow(ConceptMastery).to receive(:record_review!)

    review

    expect(ConceptMastery).to have_received(:record_review!)
      .with(response, sections: %w[code_review pattern], apply_session_countdown: true, previous_review_keys: [])
  end

  it "does not count the session again on a later batch" do
    response.update!(ai_review: { "code_review" => { "rating" => "solid" } })
    allow(reviewer).to receive(:review_sections).and_return("pattern" => review_result("solid"))
    allow(ConceptMastery).to receive(:record_review!)

    review

    expect(ConceptMastery).to have_received(:record_review!)
      .with(response, sections: %w[pattern], apply_session_countdown: false, previous_review_keys: %w[code_review])
  end

  it "reads today in the user's zone, so a caller outside a request clears the right day's error" do
    travel_to Time.utc(2026, 10, 12, 20, 0) do
      user.update!(time_zone: "Auckland", last_generation_error: "Couldn't generate",
                   last_generation_error_date: Date.new(2026, 10, 13))
      allow(reviewer).to receive(:review_sections).and_return("code_review" => review_result("solid"),
                                                              "pattern" => review_result("solid"))

      Time.use_zone("UTC") { review }

      expect(user.reload.last_generation_error_date).to be_nil
    end
  end

  it "re-checks after taking the claim and stops when another review finished the day" do
    allow(response).to receive(:claim_reviewing!).and_wrap_original do |original|
      token = original.call
      DailyResponse.where(id: response.id).update_all(
        ai_review: { "code_review" => { "rating" => "solid" }, "pattern" => { "rating" => "solid" } })
      token
    end
    expect(reviewer).not_to receive(:review_sections)

    expect(review.status).to eq(:already_reviewed)
    expect(response.reload.reviewing_since).to be_nil
  end

  it "reports a provider error and releases the claim" do
    error = ProviderError.new("boom")
    allow(reviewer).to receive(:review_sections).and_raise(error)

    outcome = review

    expect(outcome.status).to eq(:provider_error)
    expect(outcome.error).to be(error)
    expect(response.reload.reviewing_since).to be_nil
  end

  it "builds the provider inside the call, so a refused credential is a provider error" do
    allow(AiService).to receive(:for).with(user).and_raise(ProviderError::TrialEndedError.new("ended"))

    outcome = described_class.new(response, user: user).call

    expect(outcome.status).to eq(:provider_error)
    expect(response.reload.reviewing_since).to be_nil
  end

  it "reports a setup error as a handled outcome and releases the claim" do
    error = SetupError.new("Unsupported generation language: \"cobol\"")
    allow(reviewer).to receive(:review_sections).and_raise(error)

    outcome = review

    expect(outcome.status).to eq(:provider_error)
    expect(outcome.error).to be(error)
    expect(response.reload.reviewing_since).to be_nil
  end

  it "reports a set cleared while the review ran" do
    allow(reviewer).to receive(:review_sections) do
      DailyResponse.where(id: response.id).delete_all
      { "code_review" => review_result("solid"), "pattern" => review_result("solid") }
    end

    expect(review.status).to eq(:set_cleared)
  end

  def create_exercise(problem_set, date = Date.current)
    DailyExercise.create!(user: user, date: date, problem_set: problem_set, generated_at: Time.current)
  end

  def stub_reviewer(results = nil, &block)
    fake_service = instance_double(ClaudeService)
    if block
      allow(fake_service).to receive(:review_sections, &block)
    else
      allow(fake_service).to receive(:review_sections).and_return(results)
    end
    allow(AiService).to receive(:for).with(user).and_return(fake_service)
    fake_service
  end

  def review_through_provider(subject_response)
    described_class.new(subject_response, user: user).call
  end

  describe "a three-section day" do
    def create_submitted_response(date: Date.current)
      exercise = create_exercise({ "code_review" => { "question" => "q", "snippet" => "s" },
                                   "pattern" => { "title" => "t", "question" => "q" },
                                   "challenge" => { "title" => "t", "question" => "q" } }, date)
      DailyResponse.create!(user: user, daily_exercise: exercise, date: date,
                            answers: { "code_review" => "a" * 20 }, submitted_at: Time.current)
    end

    it "reviews an unanswered section in the same batch, with no grade stored and the same number of calls" do
      daily_response = create_submitted_response
      daily_response.update!(answers: { "code_review" => "a" * 20, "pattern" => "" })
      purposes = Queue.new
      allow_any_instance_of(FakeService).to receive(:call).and_wrap_original do |original, request|
        purposes << request.purpose
        original.call(request)
      end
      allow(AiService).to receive(:for).with(user).and_return(FakeService.new("key"))

      expect(review_through_provider(daily_response).status).to eq(:ready)

      daily_response.reload
      expect(daily_response).to be_fully_reviewed
      expect(daily_response.ai_review["code_review"]).to include("rating", "rubric")
      %w[pattern challenge].each do |unanswered|
        expect(daily_response.ai_review[unanswered].keys).not_to include("rating", "essential_gaps", "rubric")
        expect(daily_response.ai_review[unanswered]).to have_key("missed")
      end
      expect(Array.new(purposes.size) { purposes.pop }.tally).to eq("review_response" => 3, "assess_difficulty" => 1)
    end

    it "saves the ai_review from the user's configured provider" do
      daily_response = create_submitted_response
      stub_reviewer(
        "code_review" => { ok: true, review: { "rating" => "solid" } },
        "pattern"     => { ok: true, review: { "rating" => "solid" } },
        "challenge"   => { ok: true, review: { "rating" => "solid" } }
      )

      outcome = review_through_provider(daily_response)

      expect(outcome.status).to eq(:ready)
      expect(daily_response.reload.ai_review.keys).to match_array(%w[code_review pattern challenge])
      expect(daily_response.review_provider).to eq("anthropic")
    end

    it "logs the AI rating paired with the user's self-rating for each reviewed section" do
      daily_response = create_submitted_response
      daily_response.update!(answers: daily_response.answers.merge("pattern" => "My approach:\n#{"b" * 20}", "challenge" => "c" * 20),
                             section_ratings: { "code_review" => "right_level", "pattern" => "too_hard" })
      stub_reviewer(
        "code_review" => { ok: true, review: { "rating" => "solid" } },
        "pattern"     => { ok: true, review: { "rating" => "beginner" } },
        "challenge"   => { ok: true, review: { "rating" => "solid" } }
      )

      logged = nil
      allow(Rails.logger).to receive(:info) do |msg|
        logged = msg if msg.is_a?(String) && msg.start_with?("[difficulty_diagnostics]")
      end

      review_through_provider(daily_response)

      expect(logged).not_to be_nil
      payload = JSON.parse(logged.delete_prefix("[difficulty_diagnostics] "))

      expect(payload["event"]).to eq("review")
      expect(payload["user_id"]).to eq(user.id)
      expect(payload["date"]).to eq(daily_response.date.to_s)
      expect(payload["sections"]).to eq(
        "code_review" => { "ai_rating" => "solid",    "self_rating" => "right_level" },
        "pattern"     => { "ai_rating" => "beginner", "self_rating" => "too_hard" },
        "challenge"   => { "ai_rating" => "solid",    "self_rating" => nil }
      )
    end

    it "logs the generation exercise's date, not the response's own save-time date, when they differ" do
      exercise = create_exercise({ "code_review" => { "question" => "q", "snippet" => "s" } }, Date.current - 1)
      daily_response = DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                                             answers: { "code_review" => "a" * 20 }, submitted_at: Time.current)
      stub_reviewer("code_review" => { ok: true, review: { "rating" => "solid" } })

      logged = nil
      allow(Rails.logger).to receive(:info) do |msg|
        logged = msg if msg.is_a?(String) && msg.start_with?("[difficulty_diagnostics]")
      end

      review_through_provider(daily_response)

      payload = JSON.parse(logged.delete_prefix("[difficulty_diagnostics] "))
      expect(payload["date"]).to eq(exercise.date.to_s)
      expect(payload["date"]).not_to eq(daily_response.date.to_s)
    end

    it "does not log when every section fails" do
      daily_response = create_submitted_response
      stub_reviewer(
        "code_review" => { ok: false, error_code: "rate_limit", message: "slow down" },
        "pattern"     => { ok: false, error_code: "rate_limit", message: "slow down" },
        "challenge"   => { ok: false, error_code: "rate_limit", message: "slow down" }
      )

      expect(Rails.logger).not_to receive(:info).with(/\[difficulty_diagnostics\]/)

      expect(review_through_provider(daily_response).status).to eq(:failed)
    end

    it "abandons the review without writing mastery state if the response is destroyed mid-flight" do
      daily_response = create_submitted_response
      stub_reviewer do
        DailyResponse.where(id: daily_response.id).delete_all
        {
          "code_review" => { ok: true, review: { "rating" => "solid" } },
          "pattern"     => { ok: true, review: { "rating" => "solid" } },
          "challenge"   => { ok: true, review: { "rating" => "solid" } }
        }
      end

      outcome = nil
      expect { outcome = review_through_provider(daily_response) }.not_to change(ConceptMastery, :count)

      expect(outcome.status).to eq(:set_cleared)
      expect(DailyResponse.exists?(daily_response.id)).to be false
    end

    it "stores the provider the section's call went to" do
      daily_response = create_submitted_response
      stub_reviewer("code_review" => { ok: false, error_code: "rate_limit", failure: "short_rate_limit", provider: "openai", retry_after: 30 })

      expect(review_through_provider(daily_response).status).to eq(:failed)

      expect(daily_response.reload.review_errors["code_review"]).to include("provider" => "openai", "retry_after" => 30)
    end

    it "keeps the time each section failed, not the time the review finished, which can be a day later" do
      daily_response = create_submitted_response
      failed_at = Time.utc(2026, 10, 7, 6, 59, 30)
      stub_reviewer do
        travel_to(Time.utc(2026, 10, 7, 7, 1))
        { "code_review" => { ok: false, error_code: "rate_limit", failure: "daily_limit", provider: "gemini",
                             quota_id: "GenerateRequestsPerDayPerProjectPerModel-FreeTier", failed_at: failed_at } }
      end

      expect(review_through_provider(daily_response).status).to eq(:failed)

      expect(daily_response.reload.review_errors["code_review"]["at"]).to eq(failed_at.iso8601)
    ensure
      travel_back
    end
  end

  describe "the mastery write" do
    let(:section) { { "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" } } }

    def submitted_response
      exercise = create_exercise(section)
      user.daily_responses.create!(daily_exercise: exercise, date: Date.current,
        answers: { "code_review" => "a" * 20 }, submitted_at: Time.current,
        section_ratings: { "code_review" => "too_hard" },
        concept_tags: { "code_review" => "n_plus_one" })
    end

    before do
      fake = instance_double(ClaudeService, review_sections: {
        "code_review" => { ok: true, review: { "rating" => "developing", "correct" => "ok",
                           "missed" => "", "better_questions" => "", "next_step" => "", "improved_code" => "" } }
      })
      allow(AiService).to receive(:for).and_return(fake)
    end

    it "writes ConceptMastery state in the same transaction as the review" do
      resp = submitted_response
      review_through_provider(resp)

      expect(resp.reload.ai_review).to be_present
      expect(user.concept_masteries.find_by(concept: "n_plus_one", language: "ruby_rails")).to be_present
    end

    it "rolls back the review if the mastery write fails" do
      resp = submitted_response
      allow(ConceptMastery).to receive(:record_review!).and_raise(ActiveRecord::RecordInvalid.new(ConceptMastery.new))

      expect { review_through_provider(resp) }.to raise_error(ActiveRecord::RecordInvalid)

      expect(resp.reload.ai_review).to be_nil
      expect(resp.reviewing_since).to be_nil
    end
  end

  describe "the review claim" do
    def submitted_response(reviewing_since: nil)
      exercise = create_exercise("code_review" => { "question" => "q", "snippet" => "s" })
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "a" * 20 }, submitted_at: Time.current,
                            reviewing_since: reviewing_since)
    end

    it "reclaims the review after the in-flight marker goes stale" do
      resp = submitted_response(reviewing_since: (DailyResponse::REVIEW_CLAIM_STALE_AFTER + 1.minute).ago)
      stub_reviewer("code_review" => { ok: true, review: { "rating" => "solid" } })

      expect(review_through_provider(resp).status).to eq(:ready)

      expect(resp.reload.ai_review).to eq("code_review" => { "rating" => "solid" })
      expect(resp.reviewing_since).to be_nil
    end

    it "clears the claim when every section fails, so an immediate retry can proceed" do
      resp = submitted_response
      stub_reviewer("code_review" => { ok: false, error_code: "other", failure: "other" })

      expect(review_through_provider(resp).status).to eq(:failed)

      expect(resp.reload.reviewing_since).to be_nil
    end

    context "when another review takes the claim over during the provider call" do
      let(:takeover) { 1.second.from_now.floor(6) }

      def take_over(resp)
        DailyResponse.where(id: resp.id).update_all(reviewing_since: takeover)
      end

      it "leaves the new claim in place when this review finishes" do
        resp = submitted_response
        stub_reviewer do
          take_over(resp)
          { "code_review" => { ok: true, review: { "rating" => "solid" } } }
        end

        review_through_provider(resp)

        expect(resp.reload.reviewing_since).to eq(takeover)
      end

      it "discards its results rather than writing a review the new claim will write again" do
        resp = submitted_response
        stub_reviewer do
          take_over(resp)
          { "code_review" => { ok: true, review: { "rating" => "solid" } } }
        end
        allow(ConceptMastery).to receive(:record_review!)

        expect(review_through_provider(resp).status).to eq(:busy)

        expect(resp.reload.ai_review).to be_nil
        expect(ConceptMastery).not_to have_received(:record_review!)
      end

      it "leaves the new claim in place when the provider raises" do
        resp = submitted_response
        stub_reviewer do
          take_over(resp)
          raise ProviderError, "boom"
        end

        expect(review_through_provider(resp).status).to eq(:provider_error)

        expect(resp.reload.reviewing_since).to eq(takeover)
      end
    end
  end

  describe "a stale generation failure" do
    def submitted_response
      exercise = create_exercise("code_review" => { "question" => "q", "snippet" => "s" })
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "a" * 20 }, submitted_at: Time.current)
    end

    def stub_review(result)
      stub_reviewer("code_review" => result)
    end

    it "clears today's regeneration failure once a section is reviewed, since a review closes off regeneration" do
      resp = submitted_response
      user.update!(last_generation_error_date: Date.current, last_generation_error: "boom")
      stub_review({ ok: true, review: { "rating" => "solid" } })

      review_through_provider(resp)

      expect(user.reload.last_generation_error).to be_nil
      expect(user.last_generation_error_date).to be_nil
    end

    it "leaves it standing when no section could be reviewed" do
      resp = submitted_response
      user.update!(last_generation_error_date: Date.current, last_generation_error: "boom")
      stub_review({ ok: false, error_code: "other", failure: "outage" })

      review_through_provider(resp)

      expect(user.reload.last_generation_error).to eq("boom")
    end

    it "leaves an earlier day's failure alone" do
      resp = submitted_response
      user.update!(last_generation_error_date: Date.current - 1, last_generation_error: "yesterday")
      stub_review({ ok: true, review: { "rating" => "solid" } })

      review_through_provider(resp)

      expect(user.reload.last_generation_error).to eq("yesterday")
    end
  end

  describe "partial success and retry" do
    def submitted_response
      exercise = create_exercise(
        "code_review" => { "question" => "q", "snippet" => "s" },
        "pattern"     => { "title" => "t", "question" => "q" },
        "challenge"   => { "question" => "q" }
      )
      DailyResponse.create!(user: user, daily_exercise: exercise, date: Date.current,
                            answers: { "code_review" => "a" * 20, "pattern" => "a" * 20, "challenge" => "a" * 20 },
                            submitted_at: Time.current)
    end

    it "saves succeeded sections and records the failure reason for the rest" do
      resp = submitted_response
      stub_reviewer(
        "code_review" => { ok: true, review: { "rating" => "solid" } },
        "pattern"     => { ok: true, review: { "rating" => "developing" } },
        "challenge"   => { ok: false, error_code: "rate_limit", failure: "short_rate_limit", retry_after: 20 }
      )

      expect(review_through_provider(resp).status).to eq(:partial)

      resp.reload
      expect(resp.ai_review.keys).to match_array(%w[code_review pattern])
      expect(resp.review_errors.keys).to eq([ "challenge" ])
      expect(resp.review_errors["challenge"]).to include("kind" => "short_rate_limit", "retry_after" => 20, "at" => be_present)
      expect(resp.review_errors["challenge"]).not_to have_key("message")
      expect(resp).not_to be_fully_reviewed
      expect(resp).to be_reviewed
    end

    it "only re-requests the still-missing section on retry, and clears its error once it succeeds" do
      resp = submitted_response
      resp.update!(
        ai_review: { "code_review" => { "rating" => "solid" }, "pattern" => { "rating" => "developing" } },
        review_errors: { "challenge" => { "kind" => "short_rate_limit", "at" => Time.current.iso8601 } }
      )
      fake_service = instance_double(ClaudeService)
      allow(AiService).to receive(:for).with(user).and_return(fake_service)
      expect(fake_service).to receive(:review_sections)
        .with(user, resp.daily_exercise, resp, sections: %w[challenge])
        .and_return("challenge" => { ok: true, review: { "rating" => "strong" } })

      expect(review_through_provider(resp).status).to eq(:ready)

      resp.reload
      expect(resp).to be_fully_reviewed
      expect(resp.review_errors).to eq({})
    end

    it "does not re-decrement a paused concept's cooldown on a retry that completes the review" do
      exercise = create_exercise(
        "code_review" => { "question" => "q", "snippet" => "s", "concept" => "n_plus_one" },
        "pattern"     => { "title" => "t", "question" => "q" },
        "challenge"   => { "question" => "q" }
      )
      resp = DailyResponse.create!(
        user: user, daily_exercise: exercise, date: Date.current,
        answers: { "code_review" => "a" * 20, "pattern" => "a" * 20, "challenge" => "a" * 20 },
        submitted_at: Time.current, concept_tags: { "code_review" => "n_plus_one" }
      )
      paused = user.concept_masteries.create!(concept: "memoization", language: "ruby_rails", tier: :paused, cooldown_remaining: 2)

      stub_reviewer(
        "code_review" => { ok: true, review: { "rating" => "solid" } },
        "pattern"     => { ok: true, review: { "rating" => "solid" } },
        "challenge"   => { ok: false, error_code: "other", failure: "other" }
      )
      review_through_provider(resp)
      expect(paused.reload.cooldown_remaining).to eq(1)

      stub_reviewer("challenge" => { ok: true, review: { "rating" => "solid" } })
      review_through_provider(resp)

      expect(paused.reload.cooldown_remaining).to eq(1)
    end
  end
end
