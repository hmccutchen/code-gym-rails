require "rails_helper"

RSpec.describe CompetencyGate::Evidence do
  include AuthHelpers

  let(:user) { create_user_with_key }
  let(:start) { Date.new(2026, 1, 5) }

  def day(offset, sections = { "code_review" => {} }, owner: user, **attributes)
    date = start + offset
    exercise = DailyExercise.create!(
      user: owner, date: date, generated_at: Time.current,
      problem_set: sections.transform_values do |section|
        { "question" => "q", "snippet" => "s", "pitched_at" => section.fetch(:rung, "senior"),
          "eased" => section[:eased] }.compact
      end
    )
    DailyResponse.create!(
      user: owner, daily_exercise: exercise, date: date, submitted_at: Time.current,
      answers: sections.transform_values { |section| section.fetch(:answered, true) ? "a" * 20 : "" },
      section_ratings: sections.transform_values { |section| section.fetch(:self, "right_level") }.compact,
      ai_review: sections.transform_values do |section|
        { "rating" => section.fetch(:ai, "solid"), "rubric" => section.fetch(:rubric, AiService::RUBRIC_VERSION) }.compact
      end,
      **attributes
    )
  end

  def days(batch_size: described_class::BATCH_SIZE)
    described_class.new(user, batch_size: batch_size).to_a
  end

  it "yields a day per reviewed, rubric-stamped response, oldest first, whatever order they were written in" do
    day(2, { "code_review" => { rung: "junior" } })
    day(0, { "code_review" => { ai: "strong" }, "pattern" => { self: "too_hard" } })
    day(1)

    expect(days.map { |each_day| each_day.results.map(&:date).uniq }).to eq([ [ start ], [ start + 1 ], [ start + 2 ] ])
    expect(days.first.results).to eq([
      ReviewedSectionResults::Result.new(date: start, kind: "code_review", level: "senior",
                                         ai_rating: "strong", self_rating: "right_level"),
      ReviewedSectionResults::Result.new(date: start, kind: "pattern", level: "senior",
                                         ai_rating: "solid", self_rating: "too_hard")
    ])
  end

  it "skips drafts, unreviewed responses, other users' work and days graded before the rubric" do
    day(0, submitted_at: nil)
    day(1, ai_review: {})
    day(2, owner: create_user_with_key(email: "other@example.com"))
    day(3, { "code_review" => { rubric: nil }, "pattern" => { rubric: nil, answered: false } })
    day(4, { "code_review" => { rubric: AiService::RUBRIC_VERSION - 1 } })

    expect(days).to eq([])
  end

  # The brake reads an eased section's self-rating; growth leaves it out.
  it "carries eased sections, marked as eased" do
    day(0, { "code_review" => {}, "pattern" => { eased: true, self: "too_hard" } })

    expect(days.sole.results.map { |result| [ result.kind, result.eased, result.self_rating ] })
      .to eq([ [ "code_review", false, "right_level" ], [ "pattern", true, "too_hard" ] ])
  end

  # The gate runs on every plan, so a malformed row must not stop the day being built.
  it "skips a stamped row whose answers or problem set are not objects" do
    day(0)
    day(1).update_columns(answers: [])
    day(2).daily_exercise.update_columns(problem_set: [])

    expect(days.map { |each_day| each_day.results.map(&:date).uniq }).to eq([ [ start ] ])
  end

  it "keeps a stamped day's optional state even when none of its sections are evidence" do
    day(0, { "code_review" => { answered: false }, "pattern" => { rung: nil } })

    expect(days).to eq([ CompetencyGate::Day.new(results: [], optional: :complete) ])
  end

  it "leaves out sections graded before the rubric on a day that is otherwise stamped" do
    day(0, { "code_review" => {}, "pattern" => { rubric: nil } })

    expect(days.sole.results.map(&:kind)).to eq([ "code_review" ])
  end

  it "says whether each day answered every optional section it had" do
    day(0)
    day(1, { "code_review" => {}, "pattern" => {}, "plan_review" => {} })
    day(2, { "code_review" => { answered: false }, "pattern" => {}, "plan_review" => { answered: false } })

    expect(days.map(&:optional)).to eq(%i[none complete incomplete])
  end

  it "reads the whole post-rubric history in batches, preloading each batch's exercises" do
    7.times { |n| day(n) }
    queries = []
    callback = ->(*, payload) { queries << payload[:sql] if payload[:sql].match?(/SELECT.*"daily_(responses|exercises)"/) }

    loaded = nil
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { loaded = days(batch_size: 3) }

    expect(loaded.map { |each_day| each_day.results.sole.date }).to eq((0...7).map { |n| start + n })
    expect(queries.size).to eq(6)
  end

  # Replaying only the latest sixty responses would forget a size earned before them.
  it "keeps a size earned more than sixty responses ago across batch boundaries" do
    5.times { |n| day(n) }
    (5..70).each { |n| day(n, { "code_review" => { rung: "principal_engineer", ai: "developing" } }) }

    plans = CompetencyGate.plans(described_class.new(user, batch_size: 7), fixed_kinds: [ "code_review" ])

    expect(plans.size).to eq(71)
    expect(plans.map(&:count)).to eq([ 2, 2, 2, 2 ] + [ 3 ] * 67)
    expect(CompetencyGate.plan(days.last(60), fixed_kinds: [ "code_review" ]).count).to eq(2)
  end

  describe "CompetencyGate.for" do
    it "folds the user's history with the registry's fixed kinds" do
      5.times { |n| day(n) }

      expect(CompetencyGate.for(user)).to eq(
        CompetencyGate.plan(days, fixed_kinds: ExerciseSection.fixed.map(&:key))
      )
      expect(CompetencyGate.for(user).count).to eq(3)
    end

    it "is two with zero evidence for a user without reviewed work" do
      expect(CompetencyGate.for(user)).to have_attributes(count: 2, reason: :held)
    end
  end
end
