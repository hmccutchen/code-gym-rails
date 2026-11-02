require "rails_helper"
require Rails.root.join("script/in_memory_usage")

RSpec.describe InMemoryUsage do
  let(:usage) { [] }
  let(:result) { { input_tokens: 120, output_tokens: 30, cache_read_tokens: 5, cache_write_tokens: 2, model: "m" } }

  def log(service, purpose: "generate_exercise") = service.send(:log_usage, nil, result, purpose: purpose)

  it "keeps each call's tokens in the array it was given, and writes no ApiUsage row" do
    service = described_class.provider(ClaudeService, usage).new("no-network-key")

    expect { log(service) }.not_to change(ApiUsage, :count)
    expect(usage).to eq([ { tokens_in: 120, tokens_out: 30 } ])
  end

  it "keeps the row a script's block builds, run on the service so it can read the service's own state" do
    service = described_class.provider(ClaudeService, usage) { |result, purpose| { purpose: purpose, model: routed_model(purpose), out: result[:output_tokens] } }
                             .new("no-network-key")

    log(service, purpose: "judge_section")

    expect(usage).to eq([ { purpose: "judge_section", model: service.send(:routed_model, "judge_section"), out: 30 } ])
  end

  it "records no suggested concept" do
    service = described_class.provider(ClaudeService, usage).new("no-network-key")

    expect { service.send(:record_suggested_concept, Struct.new(:bucket, :name).new("ruby_rails", "x")) }.not_to change(SuggestedConcept, :count)
  end

  it "leaves a script's own overrides on top of it" do
    service = Class.new(described_class.provider(ClaudeService, usage)) { def self.judges_review_prose? = false }.new("no-network-key")

    expect(service.class.judges_review_prose?).to be(false)
    log(service)
    expect(usage.size).to eq(1)
  end

  it "takes the same parameters as AiService#log_usage, so a signature change fails here rather than in a billed run" do
    provider = described_class.provider(ClaudeService, usage)

    expect(provider.instance_method(:log_usage).parameters.map(&:first))
      .to eq(AiService.instance_method(:log_usage).parameters.map(&:first))
  end
end
