require "rails_helper"

RSpec.describe "ReviewTakeaway" do
  let(:section) { "code_review" }
  let(:submitted_at) { Time.current }
  let(:answers) { { section => "The write should happen first." } }
  let(:gap) { "The update and audit record can commit separately. A failed audit write may leave a change unrecorded." }
  let(:other_gap) { "A retry may repeat a successful update." }
  let(:review) do
    { "rating" => "developing", "rubric" => ReviewedSectionResults::RUBRIC_VERSION,
      "missed" => [ gap ], "essential_gaps" => [ 0 ] }
  end

  def takeaway(section_review = review, section_key: section, review_by_section: nil)
    exercise = DailyExercise.new(problem_set: { section_key => { "blocks" => [ "one", "two" ] } })
    response = DailyResponse.new(daily_exercise: exercise, submitted_at: submitted_at, answers: answers,
                                 ai_review: review_by_section || { section_key => section_review })
    ReviewTakeaway.call(response, section_key)
  end

  it "returns the intact supported entry including its qualification" do
    expect(takeaway).to eq(gap)
  end

  it "strips outer whitespace only" do
    text = "A retry may  repeat a successful update."
    expect(takeaway(review.merge("missed" => [ "  #{text} " ]))).to eq(text)
  end

  it "uses a nonblank scalar as one slot" do
    expect(takeaway(review.merge("missed" => gap))).to eq(gap)
  end

  it "counts repeated copies of one valid position once" do
    expect(takeaway(review.merge("essential_gaps" => [ 0, 0 ]))).to eq(gap)
  end

  it "does not rank multiple distinct essential gaps" do
    expect(takeaway(review.merge("missed" => [ gap, other_gap ], "essential_gaps" => [ 1, 0 ]))).to be_nil
  end

  it "addresses the raw position after a blank slot" do
    expect(takeaway(review.merge("missed" => [ " ", gap ], "essential_gaps" => [ 1 ]))).to eq(gap)
  end

  it "rejects a blank selected slot" do
    expect(takeaway(review.merge("missed" => [ " ", gap ]))).to be_nil
  end

  it "ignores other sections' missing reviews" do
    expect(takeaway(review_by_section: { section => review, "challenge" => nil })).to eq(gap)
  end

  [ nil, [], [ -1 ], [ 1 ], [ "0" ], [ 0.0 ], [ 0, nil ], "0" ].each do |positions|
    it "rejects invalid or uninformative positions #{positions.inspect}" do
      expect(takeaway(review.merge("essential_gaps" => positions))).to be_nil
    end
  end

  it "rejects missing positions" do
    expect(takeaway(review.except("essential_gaps"))).to be_nil
  end

  %w[solid strong unknown].each do |rating|
    it "does not promote a gap at rating #{rating}" do
      expect(takeaway(review.merge("rating" => rating))).to be_nil
    end
  end

  it "accepts a supported gap on a beginner review" do
    expect(takeaway(review.merge("rating" => "beginner"))).to eq(gap)
  end

  it "rejects an unstamped or outdated review" do
    expect(takeaway(review.except("rubric"))).to be_nil
    expect(takeaway(review.merge("rubric" => ReviewedSectionResults::RUBRIC_VERSION + 1))).to be_nil
  end

  it "rejects an unknown section or a malformed review" do
    expect(takeaway(section_key: "unknown")).to be_nil
    expect(takeaway("Unstructured review")).to be_nil
    expect(takeaway(review_by_section: [ review ])).to be_nil
  end

  it "rejects malformed missed values and ambiguous display matches" do
    expect(takeaway(review.merge("missed" => [ gap, nil ]))).to be_nil
    expect(takeaway(review.merge("missed" => { "0" => gap }))).to be_nil
    expect(takeaway(review.merge("missed" => [ gap, " #{gap}" ]))).to be_nil
  end

  context "when the response has not been submitted" do
    let(:submitted_at) { nil }

    it "returns no takeaway" do
      expect(takeaway).to be_nil
    end
  end

  context "when the engineer skipped the section" do
    let(:answers) { {} }

    it "returns no takeaway even with a stored grade and gap" do
      expect(takeaway).to be_nil
    end
  end

  context "with an answered fixed-score Parsons problem" do
    let(:section) { "parsons_problem" }
    let(:answers) { { section => "order:1,0" } }

    it "returns no takeaway even with a stored gap" do
      expect(takeaway).to be_nil
    end
  end

  context "with an original prose audit" do
    def audited(displayed:, original:, original_positions: [ 0 ])
      review.except("essential_gaps").merge(
        "missed" => displayed, "graded_prose" => { "missed" => original, "essential_gaps" => original_positions }
      )
    end

    it "uses the displayed positions if the raw missed prose is exactly unchanged" do
      expect(takeaway(review.merge("graded_prose" => { "missed" => [ gap ], "correct" => [ "A useful observation." ] }))).to eq(gap)
    end

    it "finds an intact original entry after displayed prose moves or merges other entries" do
      expect(takeaway(audited(displayed: [ other_gap, gap ], original: [ gap, other_gap ]))).to eq(gap)
      merged_others = "A retry may repeat a successful update or lose the audit record."
      expect(takeaway(audited(displayed: [ gap, merged_others ], original: [ gap, other_gap, "Logs may also be lost." ]))).to eq(gap)
    end

    it "requires a complete and unique match in the displayed entries" do
      [ [ "The writes might commit separately." ], [ "#{other_gap} #{gap}" ], [ gap, gap, other_gap ], [ gap, nil ] ].each do |displayed|
        expect(takeaway(audited(displayed: displayed, original: [ gap, other_gap ]))).to be_nil
      end
    end

    it "requires co-located positions when the raw prose differs even by outer whitespace" do
      expect(takeaway(review.merge("graded_prose" => { "missed" => [ " #{gap}" ] }))).to be_nil
      expect(takeaway(audited(displayed: [ gap ], original: [ " #{gap}" ]))).to eq(gap)
    end

    it "rejects conflicting or misplaced positions even if the text appears to match" do
      changed = audited(displayed: [ other_gap, gap ], original: [ gap ])
      expect(takeaway(changed.merge("essential_gaps" => [ 0 ]))).to be_nil
      expect(takeaway(changed.merge("essential_gaps" => nil))).to be_nil
      expect(takeaway(audited(displayed: [ gap ], original: [ gap ]))).to be_nil
      expect(takeaway(review.merge("graded_prose" => { "missed" => [ gap ], "essential_gaps" => [ 0 ] }))).to be_nil
    end

    it "rejects malformed audit data before projecting it" do
      [ nil, [], "Audit text", {}, { "missed" => [ gap, nil ] }, { "missed" => [ gap ], "rating" => "beginner" } ].each do |audit|
        expect(takeaway(review.merge("graded_prose" => audit))).to be_nil
      end
    end

    it "requires the displayed missed list even if the original is valid" do
      expect(takeaway(audited(displayed: [ gap ], original: [ gap, other_gap ]).except("missed"))).to be_nil
    end
  end

  context "with the conservative prose screen" do
    it "ignores punctuation inside balanced inline code" do
      text = "`User.save!` can raise if validation fails. Calling `user.valid?` first makes the validation step explicit."
      expect(takeaway(review.merge("missed" => [ text ]))).to eq(text)
    end

    it "accepts 400 characters and refuses 401 without truncating" do
      sentence = "The caller may retry after a partial update to the stored record."
      exact = sentence.delete_suffix(".") + ("x" * (400 - sentence.length)) + "."
      expect(takeaway(review.merge("missed" => [ exact ]))).to eq(exact)
      expect(takeaway(review.merge("missed" => [ exact.sub("x", "xx") ]))).to be_nil
    end

    [
      "The method can fail. One write may succeed. Another write may fail.",
      "The method can fail",
      "The method can fail?",
      "The method can fail!",
      "The method can fail. Check.",
      "The method can fail.even after a retry.",
      "The method can fail. It retries too soon.",
      "This method can fail after the first write.",
      "That update may write twice.",
      "Use the FORMER approach to keep both writes together.",
      "Refer to the explanation above for the missing step.",
      "The validation, AS DISCUSSED, can fail.",
      "The record may be missing, as noted in the review.",
      "Try the latter approach to keep the writes together.",
      "The answer below misses the second write.",
      "# The method can fail.",
      "- The method can fail.",
      "1. The method can fail.",
      "The method can fail.\nThe caller may retry.",
      "The method can fail.\rThe caller may retry.",
      "The `method is missing its closing marker.",
      "The `` has empty code markers.",
      "The ```method``` uses a code fence.",
      "The method can <em>fail</em>."
    ].each do |text|
      it "rejects #{text.inspect}" do
        expect(takeaway(review.merge("missed" => [ text ]))).to be_nil
      end
    end
  end
end
