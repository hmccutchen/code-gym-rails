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

  it "keeps an existing v1 response policy while new enrolled responses use v2 with initiation off" do
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
    stub_const("PracticePolicyMode::INITIATE_PRACTICE_POLICY", true)
    review(response, "code_review" => "solid")
    expect(response.reload.mastery_application["legacy_sections"]).to eq(%w[pattern])
    expect(user.concept_masteries.find_by!(concept: "memoization").practice_requests.keys).to eq(%w[code_review])
  end

  it "preserves requests through single/group Stop and Start and keeps eased drilling admitted" do
    stub_const("PracticePolicyMode::INITIATE_PRACTICE_POLICY", true)
    response = day(0, keys: %w[pattern])
    ConceptDrills.start!(user, concept: "memoization", bucket: "ruby_rails")
    review(response, "pattern" => "solid")
    row = user.concept_masteries.find_by!(concept: "memoization")
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
    normal = day(1, eased: false, keys: %w[pattern])
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
