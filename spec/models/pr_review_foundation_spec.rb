require "rails_helper"

RSpec.describe ProblemSetIngest, "standalone PR Review foundation" do
  let(:kind) { ExerciseSection::CodeReview }
  let(:marker) { { "review_variant" => "pr_review_v1" } }
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

  def ingest_trial(data = { "code_review" => section }, **options)
    defaults = { expected_keys: [ "code_review" ], daily: DailyKinds::DEFAULT, language: "ruby_rails",
      code_review_mode: :pr_review, code_review_files: 2..2, pitched_at: { "code_review" => "mid_level" },
      pr_review_enabled: CodeReviewPrReview.enabled? }
    described_class.call(data.deep_dup, **defaults.merge(options)).problem_set.fetch("code_review")
  end

  it "stamps only an explicitly selected trial and recognizes its evidence exclusions after switch-off" do
    stub_env("CODE_REVIEW_PR_REVIEW" => "1")
    stored = ingest_trial
    stub_env("CODE_REVIEW_PR_REVIEW" => nil)
    expect(stored).to include(marker)
    expect(stored.fetch("file_1_changed_lines")).to eq([ 2 ])
    expect(kind).to be_formative_review(stored)
    expect(kind.mastery_evidence?(stored)).to be(false)
    expect(kind.adaptation_evidence?(stored)).to be(false)
    expect(kind.planning_host?(mode: :pr_review)).to be(false)
    expect(kind).not_to be_formative_review("review_variant" => true)
  end

  it "requires exactly 1 for trusted ingestion" do
    [ nil, "0", "true", " 1" ].each do |setting|
      stub_env("CODE_REVIEW_PR_REVIEW" => setting)
      expect { ingest_trial }.to raise_error(ProviderError::InvalidResponseError)
    end
  end

  it "requires explicit admission even when the process switch is on" do
    stub_env("CODE_REVIEW_PR_REVIEW" => "1")
    expect { ingest_trial(pr_review_enabled: false) }.to raise_error(ProviderError::InvalidResponseError, /standalone/)
  end

  it "reports invalid public context with a registered trial refusal code" do
    stub_env("CODE_REVIEW_PR_REVIEW" => "1")
    expect { ingest_trial({ "code_review" => section.merge("requirements" => []) }) }
      .to raise_error(ProviderError::UnusableSectionError) { |error| expect(error.code).to eq("code_review.pr_review_artifact_invalid") }
  end

  it "rejects file paths and code outside the Ruby application scope" do
    stub_env("CODE_REVIEW_PR_REVIEW" => "1")
    [
      { "file_2_path" => "spec/services/booking_spec.rb" },
      { "file_2_path" => "app/../db/migrate/booking.rb" },
      { "file_2_path" => "app/services/booking.js" },
      { "file_2_code" => "def status(" }
    ].each do |changes|
      expect { ingest_trial({ "code_review" => section.merge(changes) }) }.to raise_error(ProviderError::UnusableSectionError)
    end
  end

  it "discards experimental fields on ordinary ingestion even when the switch is enabled" do
    stub_env("CODE_REVIEW_PR_REVIEW" => "1")
    row = ingest_trial({ "code_review" => section.merge(marker) }, code_review_mode: :application_code)
    expect(row.keys).not_to include("review_variant", "requirements")
    expect(kind.mastery_evidence?(row)).to be(true)
    expect(kind.adaptation_evidence?(row)).to be(true)
    expect(kind.planning_host?(mode: :application_code)).to be(true)
  end

  it "keeps the enabled switch out of normal weekday and weekend scheduling" do
    stub_env("CODE_REVIEW_PR_REVIEW" => "1")
    user = User.create!(email: "normal-plan@example.test")
    allow(WeightedRoll).to receive(:pick).and_call_original

    weekday = DailyPlan.for(user, language: "ruby_rails", weekend: false)
    weekend = DailyPlan.for(user, language: "ruby_rails", weekend: true)

    expect(weekday.code_review_mode).to be_in(DailyPlan::CODE_REVIEW_MODE_WEIGHTS.keys)
    expect(weekend.code_review_mode).to eq(:bug_hunt)
  end

  it "refuses trusted requests outside the standalone mid-level Ruby scope" do
    stub_env("CODE_REVIEW_PR_REVIEW" => "1")
    [ { language: "javascript" }, { pitched_at: { "code_review" => "junior" } },
      { code_review_files: 1..1 }, { assignments: { "code_review" => {} } },
      { expected_keys: %w[code_review pattern] } ].each do |options|
      expect { ingest_trial(**options) }.to raise_error(ProviderError::InvalidResponseError)
    end
    expect { ingest_trial({ "code_review" => section, "pattern" => {} }) }.to raise_error(ProviderError::InvalidResponseError)
  end

  it "refuses malformed artifacts instead of shipping ordinary Code Review" do
    stub_env("CODE_REVIEW_PR_REVIEW" => "1")
    [
      marker, { "requirements" => [] }, { "requirements" => [ " " ] },
      { "requirements" => Array.new(4, "A requirement") }, { "scenario" => " " }, { "concept" => [] },
      { "file_2_path" => section.fetch("file_1_path") }, { "file_2_code" => nil },
      { "file_1_changed" => [ "slots.any?", "not actually shown" ] },
      { "file_1_changed" => [], "file_1_changed_lines" => [ 2 ] },
      { "file_3_path" => "extra.rb" }, { "purpose" => "a bug hunt" }
    ].each do |changes|
      expect { ingest_trial({ "code_review" => section.merge(changes) }) }.to raise_error(ProviderError::UnusableSectionError)
    end
  end
end
