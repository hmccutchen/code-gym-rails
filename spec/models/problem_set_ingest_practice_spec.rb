require "rails_helper"

RSpec.describe ProblemSetIngest do
  let(:section) { { "concept" => "memoization", "pitched_at" => "principal_engineer", "eased" => true, "practice_adjustment" => "forged" } }

  def ingest(mode:, eased:, concept: "memoization")
    described_class.call({ "pattern" => section.deep_dup }, language: "ruby_rails", expected_keys: [ "pattern" ],
      daily: DailyKinds::DEFAULT, pitched_at: { "pattern" => "junior" }, eased_for: { "pattern" => [ "memoization" ] },
      assignments: { "pattern" => { concept: concept, bucket: "ruby_rails", mode: mode, eased: eased, lock_suppressed: false } },
      fixed_concepts: { "pattern" => concept }).problem_set.fetch("pattern")
  end

  it "replaces provider stamps with the resolved instruction even against reduced fallback" do
    result = ingest(mode: "normal_retry", eased: false)
    expect(result).to include("pitched_at" => "junior", "practice_adjustment" => "normal_retry")
    expect(result).not_to have_key("eased")
    expect(ingest(mode: "simplified", eased: true)).to include("eased" => true)
  end

  it "rejects a wrong assigned concept on the initial draft" do
    expect { ingest(mode: "support", eased: false, concept: "n_plus_one") }.to raise_error(ProviderError::InvalidResponseError)
  end
end
