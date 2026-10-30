require "rails_helper"

RSpec.describe SectionJudgePrompt do
  cases = {
    "code_review_locked" => [ ExerciseSection::CodeReview,
      { "question" => "What is wrong?", "snippet" => "Order.all.each { |o| o.user.name }", "concept" => "n_plus_one",
        "teaching_note" => "hint", "pitched_at" => "senior", "eased" => true, "source" => "SENTINEL-SOURCE" }, "senior", true ],
    "design_comparison" => [ ExerciseSection::DesignComparison,
      { "title" => "Rates", "scenario" => "A rates file.", "question" => "Which would you ship?", "piece_a" => "a", "piece_b" => "b",
        "concept" => "information_hiding", "answer_key" => "SENTINEL-KEY", "pitched_at" => "junior" }, "junior", false ],
    "pattern" => [ ExerciseSection::Pattern,
      { "title" => "Memoize", "why" => "Repeat work", "scenario" => "s", "question" => "When would you cache this?",
        "concept" => "memoization", "teaching_note" => "hint" }, "mid_level", false ]
  }.freeze

  # One case per branch: a locked discovery kind with server stamps, a kind with judge guidance and an answer key, a non-discovery kind.
  cases.each do |name, (kind, section, rung, locked)|
    it "renders the #{name} verdict request exactly as recorded, with no answer key or server stamp" do
      request = described_class.generate(kind: kind, section: section, rung: rung, locked: locked)

      expect(request.keys).to eq(%i[response_schema system prompt])
      expect_prompt_snapshot("judge__#{name}__system", request[:system])
      expect_prompt_snapshot("judge__#{name}__prompt", request[:prompt])
      expect_prompt_snapshot("judge__#{name}__schema", JSON.pretty_generate(request[:response_schema]))
      expect(request.values.to_json).not_to include("SENTINEL")
    end
  end

  it "shows a multi-file code review's files with the changed line numbers the page marks, and none of the provider's quotes" do
    quotes = ExerciseSection::CodeReview::CHANGED_PART
    section = CodeReviewMultiFile::SECTION.deep_dup
    section["file_1_#{quotes}"] = [ "def lifetime_total_cents", "SENTINEL-UNMARKED-QUOTE" ]
    ExerciseSection::CodeReview.reject_unusable!(section, language: "ruby_rails", file_range: 2..2)

    request = described_class.generate(kind: ExerciseSection::CodeReview, section: section, rung: "senior", locked: false)

    expect_prompt_snapshot("judge__code_review_multi_file__prompt", request[:prompt])
    expect(request[:prompt]).to include('"file_1_changed_lines"')
    expect(request[:prompt]).not_to match(/"file_\d_#{quotes}":/)
    expect(request.values.to_json).not_to include("SENTINEL")
  end

  it "never shows the judge a planted key, for any kind that plants one" do
    ExerciseSection.all.select(&:planted_key?).each do |kind|
      section = FakeService::EXERCISE_PROBLEM_SET.fetch(kind.key).deep_dup
      section["answer_key"] = section.fetch("answer_key").deep_transform_values { |_| "SENTINEL-PLANTED" }

      request = described_class.generate(kind: kind, section: section, rung: "junior", locked: false)

      expect(request.values.to_json).not_to include("SENTINEL"), "#{kind.key} leaked its key"
    end
  end

  it "sees one section and nothing about the day, the engineer or their history" do
    expect(described_class.method(:generate).parameters)
      .to eq([ [ :keyreq, :kind ], [ :keyreq, :section ], [ :keyreq, :rung ], [ :keyreq, :locked ] ])
  end

  it "asks for the checks to be worked through internally and the reply to be only the JSON verdict" do
    expect(described_class::SYSTEM)
      .to include("Work through these checks internally")
      .and include("Reply with only the JSON verdict, with no text before or after it.")
  end

  it "enumerates the rejection principles and issue types from JudgeVerdict's own constants" do
    expect(described_class::PRINCIPLE_GUIDANCE.keys).to eq(JudgeVerdict::PRINCIPLES)
    expect(described_class::SYSTEM).to include("Rejection principles, the only #{JudgeVerdict::PRINCIPLES.size}:")
    JudgeVerdict::PRINCIPLES.each do |principle|
      expect(described_class::SYSTEM).to include("- #{principle}: #{described_class::PRINCIPLE_GUIDANCE.fetch(principle)}")
    end
    expect(described_class::SYSTEM)
      .to include("Issues, the only #{JudgeVerdict::ISSUE_TYPES.size}: #{JudgeVerdict::ISSUE_TYPES.join(', ')}.")
  end
end
