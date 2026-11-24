require "rails_helper"

RSpec.describe ProblemSetIngest, "PR Review foundation" do
  let(:kind) { ExerciseSection::CodeReview }
  let(:marker) { { "review_variant" => "pr_review" } }
  let(:section) do
    {
      "scenario" => "A caller reports the service's booking availability.",
      "question" => "Describe the behavior and support your disposition.",
      "requirements" => [ "When no slot is available, the caller presents the unavailable result." ],
      "file_1_path" => "app/services/availability.rb",
      "file_1_code" => "def available?\n  slots.any?\nend",
      "file_1_changed" => [ "slots.any?" ],
      "file_2_path" => "app/services/booking.rb",
      "file_2_code" => "def status\n  availability.available? ? :available : :unavailable\nend"
    }
  end

  def ingest(data = { "code_review" => section }, **options)
    defaults = { expected_keys: [ "code_review" ], daily: DailyKinds::DEFAULT, language: "ruby_rails",
      code_review_mode: :pr_review, code_review_files: 2..2, pitched_at: { "code_review" => "mid_level" } }
    described_class.call(data.deep_dup, **defaults.merge(options))
  end

  def ingest_review(...) = ingest(...).problem_set.fetch("code_review")

  it "stamps the selected variant and uses ordinary progression evidence" do
    stored = ingest_review

    expect(stored).to include(marker)
    expect(stored.fetch("file_1_changed_lines")).to eq([ 2 ])
    expect(kind.mastery_evidence?(stored)).to be(true)
    expect(kind.adaptation_evidence?(stored)).to be(true)
    expect(kind.planning_host?(mode: :pr_review)).to be(true)
  end

  it "stamps a validated review alongside ordinary sections and strips sibling variant fields" do
    data = { "code_review" => section, "pattern" => { "question" => "Explain the pattern.", "concept" => "memoization",
      "requirements" => [ "A forged requirement" ] }.merge(marker) }

    result = ingest(data, expected_keys: %w[code_review pattern],
      pitched_at: { "code_review" => "mid_level", "pattern" => "junior" },
      assignments: { "code_review" => { mode: "normal", eased: false } })

    expect(result.problem_set.fetch("code_review")).to include(marker.merge("practice_adjustment" => "normal"))
    expect(result.problem_set.fetch("pattern")).not_to have_key("review_variant")
    expect(result.problem_set.fetch("pattern")).not_to have_key("requirements")
  end

  it "returns the usable siblings and a refusal when the intended PR Review is invalid" do
    data = { "code_review" => section.merge("requirements" => []), "pattern" => { "question" => "Explain the pattern." } }

    result = ingest(data, expected_keys: %w[code_review pattern])

    expect(result.problem_set.keys).to eq([ "pattern" ])
    expect(result.unusable_sections).to contain_exactly(have_attributes(key: "code_review", code: "code_review.pr_review_artifact_invalid"))
  end

  it "refuses a plan whose PR Review is outside the resolved slots" do
    daily = [ ExerciseSection::DesignComparison, ExerciseSection::Architecture ]
    data = FakeService::EXERCISE_PROBLEM_SET.slice("design_comparison", "architecture", "pattern", "plan_review")
      .merge("code_review" => section.merge("requirements" => []))

    expect { ingest(data, expected_keys: data.keys, daily: daily) }
      .to raise_error(ProviderError::InvalidResponseError, /active slot/)
  end

  it "ignores variant data on a retry for another section" do
    data = { "pattern" => { "question" => "Explain the pattern.", "concept" => "memoization" }, "code_review" => section }

    result = ingest(data, expected_keys: [ "pattern" ], pitched_at: { "pattern" => "junior" })

    expect(result.problem_set.keys).to eq([ "pattern" ])
  end

  it "reports invalid public context with a registered PR Review refusal code" do
    expect { ingest_review({ "code_review" => section.merge("requirements" => []) }) }
      .to raise_error(ProviderError::UnusableSectionError) { |error| expect(error.code).to eq("code_review.pr_review_artifact_invalid") }
  end

  { "scenario" => 400, "question" => 300, "requirements" => 240 }.each do |field, limit|
    describe field do
      def review_with(field, value)
        ingest_review({ "code_review" => section.merge(field => (field == "requirements" ? [ value ] : value)) })
      end

      it "keeps text at the length limit" do
        text = "a" * limit
        expect(Array(review_with(field, text).fetch(field))).to eq([ text ])
      end

      it "refuses text one character over the limit" do
        expect { review_with(field, "a" * (limit + 1)) }
          .to raise_error(ProviderError::UnusableSectionError, /invalid public context/)
      end

      it "refuses embedded newlines and other control characters" do
        [ "\n", "\u0001" ].each do |character|
          expect { review_with(field, "before#{character}after") }
            .to raise_error(ProviderError::UnusableSectionError, /invalid public context/)
        end
      end
    end
  end

  it "reports a partially unresolved changed-line list with a PR Review refusal" do
    data = { "code_review" => section.merge("file_1_changed" => [ "slots.any?", "not actually shown" ]) }

    expect { ingest_review(data) }.to raise_error(ProviderError::UnusableSectionError) { |error|
      expect(error.code).to eq("code_review.pr_review_changed_lines_unresolved")
    }
    expect(ingest_review(data, code_review_mode: :application_code).fetch("file_1_changed_lines")).to eq([ 2 ])
  end

  it "rejects file paths and code outside the Ruby application scope" do
    [
      { "file_2_path" => "spec/services/booking_spec.rb" },
      { "file_2_path" => "app/../db/migrate/booking.rb" },
      { "file_2_path" => "app/services/booking.js" },
      { "file_2_code" => "def status(" }
    ].each do |changes|
      expect { ingest_review({ "code_review" => section.merge(changes) }) }.to raise_error(ProviderError::UnusableSectionError)
    end
  end

  it "discards forged variant fields on ordinary ingestion" do
    row = ingest_review({ "code_review" => section.merge(marker) }, code_review_mode: :application_code)
    expect(row.keys).not_to include("review_variant", "requirements")
    expect(kind.mastery_evidence?(row)).to be(true)
    expect(kind.adaptation_evidence?(row)).to be(true)
    expect(kind.planning_host?(mode: :application_code)).to be(true)
  end

  it "leaves weekday and weekend selection unchanged" do
    user = User.create!(email: "normal-plan@example.test")
    allow(WeightedRoll).to receive(:pick).and_call_original

    weekday = DailyPlan.for(user, language: "ruby_rails", weekend: false)
    weekend = DailyPlan.for(user, language: "ruby_rails", weekend: true)

    expect(weekday.code_review_mode).to be_in(DailyPlan::CODE_REVIEW_MODE_WEIGHTS.keys)
    expect(weekend.code_review_mode).to eq(:bug_hunt)
  end

  it "refuses a selected review outside the mid-level Ruby application scope" do
    [ { language: "javascript" }, { pitched_at: { "code_review" => "junior" } }, { pitched_at: nil },
      { code_review_files: 1..1 }, { code_review_source: Object.new } ].each do |options|
      expect { ingest_review(**options) }.to raise_error(ProviderError::InvalidResponseError)
    end
  end

  it "refuses malformed artifacts instead of shipping ordinary Code Review" do
    [
      marker, { "requirements" => [] }, { "requirements" => [ " " ] },
      { "requirements" => Array.new(4, "A requirement") }, { "scenario" => " " }, { "concept" => [] },
      { "file_2_path" => section.fetch("file_1_path") }, { "file_2_code" => nil },
      { "file_1_changed" => [], "file_1_changed_lines" => [ 2 ] },
      { "file_3_path" => "extra.rb" }, { "purpose" => "a bug hunt" }
    ].each do |changes|
      expect { ingest_review({ "code_review" => section.merge(changes) }) }.to raise_error(ProviderError::UnusableSectionError)
    end
  end
end
