require "rails_helper"
require Rails.root.join("script/gemini_structured_output_check")

RSpec.describe GeminiStructuredOutputCheck do
  let(:out) { StringIO.new }
  let(:posted) { [] }

  def reply(text)
    { "steps" => [ { "type" => "model_output", "content" => [ { "type" => "text", "text" => text } ] } ],
      "usage" => { "total_input_tokens" => 10, "total_output_tokens" => 7 } }.to_json
  end

  before do
    requests = posted
    # In DEFAULT_FIXTURES order: the design comparison, then the code review.
    responses = [ [ 200, {}, reply({ status: "keep", better: "b" }.to_json) ],
                  [ 400, {}, { error: { message: "Unknown name \"const\"" } }.to_json ] ]
    connection = Faraday.new do |f|
      f.adapter :test do |stub|
        stub.post(GeminiService::API_URL) do |env|
          requests << JSON.parse(env.body)
          responses.shift
        end
      end
    end
    allow(Faraday).to receive(:new).and_return(connection)
  end

  it "sends each fixture with its kind's verdict schema on the production route" do
    described_class.new(api_key: "AIzaCheck", out: out).run

    expect(posted.map { |body| body["model"] }).to all(eq(GeminiService::DEFAULT_ROUTE[:model]))
    expect(posted.map { |body| body.dig("response_format", "schema") }).to eq(
      [ ExerciseSection::DesignComparison, ExerciseSection::CodeReview ].map { |kind| JSON.parse(JudgeVerdict.schema_for(kind).to_json) }
    )
  end

  it "reports a parsed verdict and a refused schema apart" do
    rows = described_class.new(api_key: "AIzaCheck", out: out).run

    expect(rows.map(&:outcome)).to eq(%i[parsed refused])
    expect(out.string).to include("status=keep").and include("Unknown name").and include("Schema accepted on 1 of 2; verdict parsed on 1.")
  end

  it "writes no usage rows" do
    expect { described_class.new(api_key: "AIzaCheck", out: out).run }.not_to change(ApiUsage, :count)
  end

  it "refuses a fixture name that does not exist" do
    expect { described_class.new(api_key: "AIzaCheck", fixtures: %w[missing]) }.to raise_error(ArgumentError, /missing/)
  end
end
