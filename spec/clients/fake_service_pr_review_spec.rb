require "rails_helper"

RSpec.describe FakeService, "Authentic PR Review" do
  let(:user) do
    User.create!(email: "fake-pr-review@example.com", provider: "fake", api_keys: { "fake" => "fake-test-key" }, skill_level: "mid_level")
  end
  let(:service) { described_class.new(user.api_key) }
  let(:kind) { ExerciseSection::CodeReview }

  it "delivers, judges and grades both cases with the same public task and zero paid tokens" do
    plan = DailyPlan.for(user, language: "ruby_rails").with(
      selected_kinds: [ kind ], code_review_mode: :pr_review, code_review_files: :multi, code_review_source: nil, code_review_gotcha: nil
    )
    artifacts = %w[acceptable flawed].map.with_index do |target, index|
      allow(DailyPlan).to receive(:for).and_return(plan.with(pr_review_target: target))

      result = service.generate_judged_exercise(user, language: "ruby_rails")
      section = result.problem_set.fetch(kind.key)

      expect(section).to include("review_variant" => "pr_review")
      expect(section.fetch("answer_key")).to include("case" => target)
      expect(section.fetch("file_2_changed_lines")).not_to be_empty
      expect(result.outcomes.fetch(kind.key)).to include(status: :keep)
      grade = review_case(section, date: Date.current - index)
      expect(grade).to include(
        ok: true, review: a_hash_including("rating" => "solid", "ungradable" => false, "disposition" => be_present)
      )
      expect(grade.fetch(:review).keys).not_to include("artifact_case", "assessment")
      section
    end

    expect(artifacts.map { |section| section.slice("question", "scenario", "requirements") }.uniq.size).to eq(1)
    expect(artifacts.map { |section| section.fetch("file_2_code") }.uniq.size).to eq(2)
    expect(ApiUsage.pluck(:tokens_in, :tokens_out).uniq).to eq([ [ 0, 0 ] ])
  end

  it "returns the PR Review grade fields and preserves the ordinary canned grade" do
    ordinary = 'Grade ONLY the "code_review" section from the day\'s context above.'
    reply = described_class::REPLIES.fetch("review_response")
    %w[acceptable flawed].each do |target|
      variant = "Grade ONLY the \"code_review\" PR Review section.\nPrivate cross-check for this submitted section only:\n" + { "case" => target }.to_json
      expect(JSON.parse(reply.call(variant))).to include(
        "rating" => "solid", "ungradable" => false, "artifact_case" => target, "assessment" => "sound",
        "comprehension" => be_present, "evidence" => be_present, "disposition" => be_present
      )
    end
    expect(JSON.parse(reply.call(ordinary))).to eq(described_class::REVIEW_SECTION)
  end

  def review_case(section, date:)
    daily = DailyExercise.create!(user: user, date: date, generated_at: Time.current, language: "ruby_rails",
      problem_set: { "code_review" => section })
    answer = if section.dig("answer_key", "case") == "acceptable"
      "Approve. With no slots the check is false, so the caller returns :unavailable as required."
    else
      "Request changes. With no slots the check is false, but the caller returns :available."
    end
    response = DailyResponse.create!(user: user, daily_exercise: daily, date: date, submitted_at: Time.current,
      answers: { "code_review" => answer })
    response.claim_reviewing!

    service.review_sections(user, daily, response, sections: [ "code_review" ]).fetch("code_review")
  end
end
