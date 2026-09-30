require "rails_helper"

RSpec.describe TrackGraduation::Evidence do
  include AuthHelpers

  let(:user) { create_user_with_key }
  let(:today) { Date.new(2026, 10, 14) }

  def day(days_ago, sections = { "code_review" => { rung: "junior" } }, owner: user, **attributes)
    date = today - days_ago
    exercise = DailyExercise.create!(
      user: owner, date: date, generated_at: Time.current,
      problem_set: sections.transform_values do |section|
        { "question" => "q", "snippet" => "s", "pitched_at" => section[:rung], "eased" => section[:eased] }.compact
      end
    )
    DailyResponse.create!(
      user: owner, daily_exercise: exercise, date: date, submitted_at: Time.current,
      answers: sections.transform_values { |section| section.fetch(:answered, true) ? "a" * 20 : "" },
      section_ratings: sections.transform_values { |section| section.fetch(:self, "right_level") }.compact,
      ai_review: sections.reject { |_, section| section[:unreviewed] }.transform_values do |section|
        { "rating" => section.fetch(:ai, "solid"), "correct" => "c" }.compact
      end,
      **attributes
    )
  end

  it "groups results by kind in date order, independent of insertion order" do
    day(1, { "code_review" => { rung: "senior", self: "too_hard" }, "pattern" => { rung: "junior" } })
    day(3, { "code_review" => { rung: "junior", ai: "strong" } })
    day(2, { "code_review" => { rung: "junior" }, "pattern" => { rung: "senior" } })

    results = described_class.for(user).results

    expect(results.keys).to contain_exactly("code_review", "pattern")
    expect(results["code_review"].map(&:date)).to eq([ today - 1, today - 2, today - 3 ])
    expect(results["pattern"].map(&:date)).to eq([ today - 1, today - 2 ])
    expect(results["code_review"].first).to have_attributes(
      level: "senior", ai_rating: "solid", self_rating: "too_hard"
    )
    expect(results["code_review"].last.ai_rating).to eq("strong")
  end

  it "leaves out skipped, eased, historically unstamped and unreviewed sections" do
    day(1, { "code_review" => { rung: "junior", answered: false } })
    day(2, { "code_review" => { rung: "junior", eased: true } })
    day(3, { "code_review" => {} })
    day(4, { "code_review" => { rung: "junior", unreviewed: true }, "pattern" => { rung: "junior", answered: false } })

    expect(described_class.for(user).results).to eq({})
  end

  it "accepts historical stamps without an eased field" do
    response = day(1)
    expect(response.daily_exercise.problem_set["code_review"]).not_to have_key("eased")
    expect(described_class.for(user).results["code_review"].size).to eq(1)
  end

  it "ignores missing AI ratings even when the self-rating says too_hard" do
    day(1, { "code_review" => { rung: "senior", ai: nil, self: "too_hard" } })

    expect(described_class.for(user).results).to eq({})
  end

  it "retains a missing self-rating as unfavourable evidence" do
    day(1, { "code_review" => { rung: "junior", self: nil } })

    result = described_class.for(user).results.fetch("code_review").sole
    expect(result.self_rating).to be_nil
    expect(result).not_to be_favourable
  end

  it "reads only the active alternate sections, even when others have answers and ratings" do
    sections = %w[code_review architecture challenge plan_review ambiguity_hunt].index_with { { rung: "junior" } }
    response = day(1, sections)

    expect(response.daily_exercise.active_section_keys.size).to eq(3)
    expect(described_class.for(user).results.keys).to eq(response.daily_exercise.active_section_keys)
  end

  it "ignores orphaned answers and uses the existing answer completion rule" do
    response = day(1, { "code_review" => { rung: "junior" }, "pattern" => { rung: "junior" } })
    response.update!(answers: { "code_review" => "too short", "pattern" => "a" * 20, "architecture" => "a" * 20 })

    expect(described_class.for(user).results.keys).to eq([ "pattern" ])
  end

  it "excludes drafts and other users' responses" do
    day(1, submitted_at: nil)
    day(2, owner: create_user_with_key(email: "other@example.com"))

    evidence = described_class.for(user)
    expect(evidence.results).to eq({})
    expect(evidence.newest_date).to be_nil
  end

  it "reports the newest reviewed date even when that response supplies no eligible sections" do
    day(3)
    day(2, { "code_review" => { rung: "junior", answered: false } })
    day(1, ai_review: {})
    day(0, ai_review: nil)

    evidence = described_class.for(user)
    expect(evidence.newest_date).to eq(today - 2)
    expect(evidence.results["code_review"].map(&:date)).to eq([ today - 3 ])
  end

  it "has no newest date when no response has a review" do
    day(1, ai_review: {})
    day(0, ai_review: nil)

    expect(described_class.for(user).newest_date).to be_nil
  end

  it "returns empty evidence for a user without responses" do
    evidence = described_class.for(user)
    expect(evidence.results).to eq({})
    expect(evidence.newest_date).to be_nil
  end

  it "bounds the load to 60 reviewed responses and preloads their exercises" do
    expect(described_class::RESPONSE_WINDOW).to eq(60)
    (1..described_class::RESPONSE_WINDOW + 1).each { |days_ago| day(days_ago) }
    day(0, ai_review: {})
    user.reload
    queries = []
    callback = ->(*, payload) { queries << payload[:sql] if payload[:sql].match?(/SELECT.*"daily_(responses|exercises)"/) }
    evidence = nil

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      evidence = described_class.for(user)
    end

    expect(evidence.results["code_review"].map(&:date)).to eq((1..described_class::RESPONSE_WINDOW).map { |n| today - n })
    expect(evidence.newest_date).to eq(today - 1)
    expect(queries.size).to eq(2)
    expect(queries.first).to include("LIMIT")
  end

  describe "TrackGraduation.for" do
    before { user.update!(section_kind_levels: { "code_review" => "junior" }) }

    it "delegates stored evidence and preferences to the proposal decision without writing" do
      3.times { |n| day(n) }
      attributes = user.attributes

      proposal = TrackGraduation.for(user)

      expect(proposal).to eq(TrackGraduation::Proposal.new(
        basis: :own,
        steps: [ TrackGraduation::Step.new(kind: "code_review", from: "junior", to: "senior", results_at_level: 3) ]
      ))
      expect(user.reload.attributes).to eq(attributes)
    end

    it "passes locks and cutoffs to the proposal decision" do
      3.times { |n| day(n) }
      user.update!(locked_section_kinds: [ "code_review" ])
      expect(TrackGraduation.for(user)).to be_nil

      user.update!(locked_section_kinds: [], track_evidence_cutoffs: {
        "code_review" => { "level" => "junior", "through" => (today - 2).iso8601 }
      })
      expect(TrackGraduation.for(user)).to be_nil
    end

    it "returns no proposal when there is no evidence to advance the lead" do
      expect(TrackGraduation.for(user)).to be_nil
    end
  end
end
