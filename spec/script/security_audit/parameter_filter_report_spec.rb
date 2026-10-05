require "rails_helper"
require Rails.root.join("script/security_audit/parameter_filter_report")

RSpec.describe ParameterFilterReport do
  let(:out) { StringIO.new }

  it "reports the app's current filter as the audit describes it" do
    expect(described_class.new.results.to_h).to eq(
      "email" => :filtered,
      "code" => :logged,
      "api_key" => :filtered,
      "user.name" => :logged,
      "user.api_keys" => :filtered,
      "response.answers.code_review" => :logged,
      "message" => :logged,
      "question" => :logged,
      "pseudocode" => :logged,
      "prior_alternates" => :logged,
      "p256dh" => :logged,
      "auth" => :logged,
      "endpoint" => :logged
    )
  end

  it "follows nested hashes and arrays, and partial matches" do
    results = described_class.new(filter_parameters: [ :code, :answers, :alternates ]).results.to_h

    expect(results).to include("code" => :filtered, "response.answers" => :filtered, "prior_alternates" => :filtered,
                               "pseudocode" => :filtered, "email" => :logged)
  end

  it "prints one line per parameter" do
    described_class.new(out: out).report

    expect(out.string.lines.size).to eq(13)
    expect(out.string).to match(/^code\s+LOGGED$/).and match(/^email\s+filtered$/)
  end
end
