require "rails_helper"

RSpec.describe ExerciseSection::CodeReview::BugHunt do
  describe ".mode?" do
    it "is true for the bug_hunt mode only" do
      expect(described_class.mode?(:bug_hunt)).to be(true)
      expect(described_class.mode?(:application_code)).to be(false)
      expect(described_class.mode?(nil)).to be(false)
    end
  end

  describe ".section?" do
    it "reads a section with a purpose as a bug_hunt section" do
      expect(described_class.section?({ "purpose" => "Remove every even number." })).to be(true)
      expect(described_class.section?({ "snippet" => "x" })).to be(false)
      expect(described_class.section?(nil)).to be(false)
    end
  end
end

RSpec.describe ExerciseSection::CodeReview do
  describe "the planning and mastery hooks" do
    def section_for(mode)
      mode == :bug_hunt ? { "purpose" => "Remove every even number.", "snippet" => "x" } : { "snippet" => "x" }
    end

    it "agree for every mode: a section that is not mastery evidence is never planned onto" do
      %i[application_code test_file schema_review bug_hunt].each do |mode|
        expect(described_class.planning_host?(mode: mode)).to eq(described_class.mastery_evidence?(section_for(mode))), mode.to_s
      end
    end

    it "keep bug_hunt out of both" do
      expect(described_class.planning_host?(mode: :bug_hunt)).to be(false)
      expect(described_class.mastery_evidence?(section_for(:bug_hunt))).to be(false)
    end

    it "leave every other kind a planning host and mastery evidence" do
      (ExerciseSection.all - [ described_class ]).each do |kind|
        expect(kind.planning_host?(mode: :bug_hunt)).to be(true)
        expect(kind.mastery_evidence?({ "snippet" => "x" })).to be(true)
      end
    end
  end

  describe ".concept_shown_before_submission?" do
    it "hides the concept of a bug_hunt section only" do
      expect(described_class.concept_shown_before_submission?({ "purpose" => "Sum the prices." })).to be(false)
      expect(described_class.concept_shown_before_submission?({ "snippet" => "x" })).to be(true)
      (ExerciseSection.all - [ described_class ]).each do |kind|
        expect(kind.concept_shown_before_submission?({ "purpose" => "Sum the prices." })).to be(true)
      end
    end
  end

  describe ".bug_hunt?" do
    it "reads the purpose field" do
      expect(described_class.bug_hunt?({ "purpose" => "Sum the prices." })).to be(true)
      expect(described_class.bug_hunt?({ "snippet" => "x" })).to be(false)
    end
  end
end

RSpec.describe ExerciseSection::CodeReview, "a bug_hunt section at ingest" do
  def snippet(lines = 6) = Array.new(lines) { |index| "total#{index} = 1" }.join("\n")

  def section(**overrides)
    { "question" => "What's wrong, why, and how would you fix it?", "purpose" => "Remove every even number from nums.",
      "snippet" => snippet, "concept" => "array_mutation_pitfalls" }.merge(overrides.transform_keys(&:to_s))
  end

  def refusal(section)
    described_class.reject_unusable!(section, language: "ruby_rails", mode: :bug_hunt)
    nil
  rescue ProviderError::UnusableSectionError => e
    e.code
  end

  it "keeps a section with a one-line purpose and at most 10 lines of code" do
    expect(refusal(section(snippet: snippet(10)))).to be_nil
  end

  {
    "code_review.purpose_missing"   => { purpose: " " },
    "code_review.snippet_missing"   => { snippet: "" },
    "code_review.purpose_too_long"  => { purpose: "x" * 161 },
    "code_review.bug_hunt_too_long" => { snippet: Array.new(11) { |index| "total#{index} = 1" }.join("\n") },
    "code_review.output_shown"      => { snippet: "nums = [1, 2]\nnums.sum # => 3" }
  }.each do |code, overrides|
    it "refuses with #{code}" do
      expect(refusal(section(**overrides))).to eq(code)
    end
  end

  it "refuses a purpose that runs over two lines" do
    expect(refusal(section(purpose: "Remove every even number\nfrom nums."))).to eq("code_review.purpose_missing")
  end

  it "refuses a JavaScript result comment too" do
    expect(refusal(section(snippet: "const total = sum([1, 2]);\ntotal; // -> 3"))).to eq("code_review.output_shown")
  end

  it "counts shown lines, so blank lines don't count toward the cap" do
    expect(refusal(section(snippet: snippet(10).gsub("\n", "\n\n")))).to be_nil
  end

  it "drops any file fields a provider sent" do
    kept = section(file_1_path: "a.rb", file_1_code: "x = 1")
    described_class.reject_unusable!(kept, language: "ruby_rails", mode: :bug_hunt)

    expect(kept).not_to have_key("file_1_path")
    expect(kept).not_to have_key("file_1_code")
  end

  it "deletes a purpose a provider sent on any other mode, so the section never reads as a bug_hunt" do
    other = section
    described_class.reject_unusable!(other, language: "ruby_rails", mode: :application_code)

    expect(other).not_to have_key("purpose")
    expect(described_class.bug_hunt?(other)).to be(false)
  end

  it "drops a diagram when the section is arranged" do
    arranged = section(diagram: "graph TD; A-->B")
    described_class.arrange!(arranged)

    expect(arranged).not_to have_key("diagram")
  end

  describe "the stored key" do
    let(:key) do
      { "issue" => "`nums.each` skips an element after each delete.", "why_it_matters" => "Adjacent evens survive.",
        "fix" => "Use `reject`.",
        "witness" => { "call" => "remove_evens([1, 2, 4, 5])", "expected" => "[1, 5]", "returns" => "[1, 4, 5]" },
        "looks_right_on" => { "call" => "remove_evens([1, 2, 3, 4])", "expected" => "[1, 3]" },
        "fixed_snippet" => "def remove_evens(nums) = nums.reject(&:even?)" }
    end

    it "keeps the witness, looks_right_on and fixed_snippet on a bug_hunt section" do
      expect(described_class.normalize_planted_key(section("answer_key" => key))).to eq(key)
    end

    it "drops an optional field that is incomplete and keeps the rest of the key" do
      partial = key.merge("witness" => { "call" => "remove_evens([2, 4])", "expected" => "[]" }, "fixed_snippet" => " ")

      expect(described_class.normalize_planted_key(section("answer_key" => partial)))
        .to eq(key.except("witness", "fixed_snippet"))
    end

    it "keeps only the three fields on any other section" do
      other = { "snippet" => snippet, "answer_key" => key }

      expect(described_class.normalize_planted_key(other).keys).to eq(described_class::KEY_FIELDS)
    end

    it "still drops the whole key when a required field is missing" do
      expect(described_class.normalize_planted_key(section("answer_key" => key.except("fix")))).to be_nil
    end

    it "quotes only the issue, since a witness holds inputs that are not in the code" do
      expect(described_class.quoted_key_texts(key)).to eq([ key["issue"] ])
    end

    it "measures every optional text against the key's length limit" do
      long = key.merge("fixed_snippet" => "x" * (PlantedKey::MAX_LENGTH + 1))

      expect(PlantedKey.too_long?(described_class.normalize_planted_key(section("answer_key" => long)))).to be(true)
    end
  end
end
