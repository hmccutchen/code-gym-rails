require "rails_helper"
require Rails.root.join("script/security_audit/parameter_filter_report")

RSpec.describe ParameterFilterReport do
  let(:out) { StringIO.new }

  it "reports the app's current filter, with the L1 and A5 fixes in place" do
    expect(described_class.new.results.to_h).to eq(
      "email" => :filtered,
      "code" => :filtered,
      "api_key" => :filtered,
      "user.name" => :logged,
      "user.api_keys" => :filtered,
      "response.answers" => :filtered,
      "message" => :filtered,
      "thread" => :filtered,
      "question" => :filtered,
      "pseudocode" => :filtered,
      "prior_alternates" => :filtered,
      "p256dh" => :filtered,
      "auth" => :filtered,
      "endpoint" => :logged
    )
  end

  it "follows nested hashes and arrays, and partial matches" do
    results = described_class.new(filter_parameters: [ :code, :answers, :alternates, :content ]).results.to_h

    expect(results).to include("code" => :filtered, "response.answers" => :filtered, "prior_alternates" => :filtered,
                               "pseudocode" => :filtered, "thread.content" => :filtered, "thread.role" => :logged,
                               "email" => :logged)
  end

  it "prints one line per parameter" do
    described_class.new(out: out).report

    expect(out.string.lines.size).to eq(14)
    expect(out.string).to match(/^code\s+filtered$/).and match(/^endpoint\s+LOGGED$/)
  end
end
