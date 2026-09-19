require "rails_helper"
require Rails.root.join("script/concept_reference_calibration")

RSpec.describe ConceptReferenceCalibration do
  let(:out) { StringIO.new }
  let(:seen) { [] }
  let(:api_key) { "sk-ant-calibration-runner" }
  let(:js_concept) { AiService::JS_CONCEPTS.first }

  def calibration(provider: "claude", **options)
    described_class.new(provider: provider, api_key: provider == "claude" ? api_key : "AIzaCalibration", out: out, **options)
  end

  def claude_reply(text = FakeService::CONCEPT_REFERENCE.to_json)
    [ 200, {}, { "content" => [ { "type" => "text", "text" => text } ],
                 "usage" => { "input_tokens" => 70, "output_tokens" => 30 } }.to_json ]
  end

  def gemini_reply(text = FakeService::CONCEPT_REFERENCE.to_json)
    [ 200, {}, { "steps" => [ { "type" => "model_output", "content" => [ { "type" => "text", "text" => text } ] } ],
                 "usage" => { "total_input_tokens" => 70, "total_output_tokens" => 30 } }.to_json ]
  end

  # The real connection, with only its adapter swapped: headers, timeouts and
  # the retry policy are the provider's own, so retried attempts and the auth
  # header are observable. Each build_connection call yields a fresh
  # connection, since Faraday locks a stack after its first request and the
  # harness adds its attempt counter to the connection it is handed.
  def stub_provider(provider_class, &reply)
    allow_any_instance_of(provider_class).to receive(:build_connection).and_wrap_original do |original|
      original.call.tap do |conn|
        conn.adapter :test do |stub|
          stub.post(provider_class::API_URL) do |env|
            seen << { timeout: env.request.timeout, long_running: env.request.context.to_h[:long_running],
                      model: JSON.parse(env.body)["model"], headers: env.request_headers }
            reply.call(env)
          end
        end
      end
    end
  end

  def stub_claude(replies = nil)
    stub_provider(ClaudeService) { replies ? replies.shift : claude_reply }
  end

  describe ".key_variable_for" do
    it "names the environment variable each provider's key is read from" do
      expect(described_class.key_variable_for("claude")).to eq("ANTHROPIC_API_KEY")
      expect(described_class.key_variable_for("gemini")).to eq("GEMINI_API_KEY")
      expect(described_class.key_variable_for("openai")).to be_nil
    end
  end

  describe ".default_sample" do
    it "covers every bucket a user can hold with a tradeoff concept where the bucket has one" do
      sample = described_class.default_sample

      expect(sample.map(&:first).uniq).to match_array(AiService::LANGUAGE_CONFIG.keys)
      expect(sample.map(&:last) & AiService::TRADEOFF_CONCEPTS).not_to be_empty
      expect(sample).to eq(described_class.default_sample)
    end
  end

  describe "#run" do
    it "measures each sample per repeat in sequence, then the first samples at once, against the deployed route" do
      stub_claude
      sample = described_class.default_sample

      records = calibration(repeats: 2, concurrency: 3).run

      expect(records.count { |r| r.mode == :sequential }).to eq(sample.size * 2)
      expect(records.count { |r| r.mode == :concurrent }).to eq(3)
      expect(records.map { |r| [ r.bucket, r.concept ] }.uniq).to match_array(sample)
      expect(records.map(&:outcome).uniq).to eq([ :ok ])
      expect(records.map(&:model).uniq).to eq([ ClaudeService::MODEL_FOR_PURPOSE.fetch("generate_concept_reference", ClaudeService::DEFAULT_ROUTE)[:model] ])
      expect(records.map(&:tokens_in).uniq).to eq([ 70 ])
      expect(records.map(&:tokens_out).uniq).to eq([ 30 ])
      expect(records.map(&:provider).uniq).to eq([ "claude" ])
      expect(records.map(&:seconds)).to all(be >= 0)
    end

    it "writes no usage, reference or suggested-concept rows" do
      stub_claude

      expect { calibration(repeats: 1, concurrency: 1).run }
        .not_to change { [ ApiUsage.count, ConceptReference.count, SuggestedConcept.count ] }
    end

    it "prints one line per record with its outcome, attempts and tokens, and a per-mode summary" do
      stub_claude

      calibration(repeats: 1, concurrency: 1).run([ [ "architecture", "sync_vs_async" ] ])

      expect(out.string).to include("claude claude-sonnet-5 · architecture/sync_vs_async · sequential · ")
        .and include(" · ok · 1 attempt · 70 in / 30 out")
        .and include("architecture/sync_vs_async · concurrent · ")
        .and match(/^sequential: n=1 /).and match(/^concurrent: n=1 /)
        .and include("over #{AiService::CONCEPT_REFERENCE_READ_TIMEOUT}s (CONCEPT_REFERENCE_READ_TIMEOUT)")
        .and include("retries").and include("Queue wait")
    end

    it "prints neither the key nor the reference text" do
      stub_claude

      calibration(repeats: 1, concurrency: 1).run([ [ "ruby_rails", "n_plus_one" ] ])

      expect(out.string).not_to include(api_key)
      expect(out.string).not_to include(FakeService::CONCEPT_REFERENCE["tagline"])
    end

    it "records a timed-out call as a timeout and carries on to the next sample" do
      replies = [ nil, claude_reply ]
      stub_provider(ClaudeService) { replies.shift or raise Faraday::TimeoutError, "Net::ReadTimeout" }

      records = calibration(repeats: 1, concurrency: 0).run([ [ "ruby_rails", "n_plus_one" ], [ "javascript", js_concept ] ])

      expect(records.map(&:outcome)).to eq([ :timeout, :ok ])
      expect(records.first.attempts).to eq(1)
      expect(calibration.summary(records)[:sequential]).to include(n: 2, timeouts: 1, failures: 0)
      expect(out.string).to include("n_plus_one · sequential · ").and include(" · timeout · ")
    end

    it "records a malformed reply as a failure rather than aborting the run" do
      stub_claude([ claude_reply("not json at all"), claude_reply ])

      records = calibration(repeats: 1, concurrency: 0).run([ [ "ruby_rails", "n_plus_one" ], [ "javascript", js_concept ] ])

      expect(records.map(&:outcome)).to eq([ "AiService::InvalidResponseError", :ok ])
      expect(calibration.summary(records)[:sequential]).to include(failures: 1, timeouts: 0)
    end

    it "sends the deployed read timeout unless told otherwise, and keeps an override long-running" do
      stub_claude
      calibration(repeats: 1, concurrency: 0).run([ [ "ruby_rails", "n_plus_one" ] ])
      expect(seen.last).to include(timeout: AiService::CONCEPT_REFERENCE_READ_TIMEOUT, long_running: true)

      calibration(repeats: 1, concurrency: 0, timeout: 240).run([ [ "ruby_rails", "n_plus_one" ] ])
      expect(seen.last).to include(timeout: 240, long_running: true)
    end

    it "counts the attempts a retried call actually made" do
      stub_claude([ [ 500, {}, "{}" ], claude_reply ])

      records = calibration(repeats: 1, concurrency: 0).run([ [ "ruby_rails", "n_plus_one" ] ])

      expect(records.first.attempts).to eq(2)
      expect(records.first.outcome).to eq(:ok)
      expect(out.string).to include(" · 2 attempts · ")
    end

    it "runs against Gemini with its own key header" do
      stub_provider(GeminiService) { gemini_reply }

      records = calibration(provider: "gemini", repeats: 1, concurrency: 0).run([ [ "ruby_rails", "n_plus_one" ] ])

      expect(records.map(&:outcome)).to eq([ :ok ])
      expect(records.first.model).to eq(GeminiService::DEFAULT_ROUTE[:model])
      expect(seen.last[:headers]["x-goog-api-key"]).to eq("AIzaCalibration")
    end

    it "skips the concurrent phase when concurrency is zero" do
      stub_claude

      records = calibration(repeats: 1, concurrency: 0).run([ [ "ruby_rails", "n_plus_one" ] ])

      expect(records.map(&:mode)).to eq([ :sequential ])
      expect(out.string).not_to include("concurrent")
    end

    it "refuses a concept outside its bucket's vocabulary before calling anything" do
      stub_claude

      expect { calibration.run([ [ "ruby_rails", "sync_vs_async" ] ]) }.to raise_error(ArgumentError, /ruby_rails\/sync_vs_async/)
      expect { calibration.run([ [ "cobol", "n_plus_one" ] ]) }.to raise_error(ArgumentError, /cobol/)
      expect(seen).to be_empty
    end

    it "refuses an unknown provider" do
      expect { calibration(provider: "openai") }.to raise_error(ArgumentError, /claude, gemini/)
    end

    # At or under READ_TIMEOUT the providers stop marking the request
    # long_running, so a timeout would retry into billed attempts the deployed
    # call never makes; the run would measure a different policy.
    it "refuses a timeout the retry guard would not treat as final" do
      expect { calibration(timeout: AiService::READ_TIMEOUT) }.to raise_error(ArgumentError, /READ_TIMEOUT.*final/)
      expect { calibration(timeout: AiService::READ_TIMEOUT + 1) }.not_to raise_error
    end

    it "refuses a negative repeat or concurrency count" do
      expect { calibration(concurrency: -1) }.to raise_error(ArgumentError, /concurrency/)
      expect { calibration(repeats: -1) }.to raise_error(ArgumentError, /repeats/)
      expect { calibration(repeats: 0, concurrency: 0) }.not_to raise_error
    end
  end

  describe "#summary" do
    it "reports n, spread, timeouts, failures and how many ran past the deployed timeout per mode" do
      over = AiService::CONCEPT_REFERENCE_READ_TIMEOUT + 1
      records = [ 10, 20, over, 40, 50 ].map do |seconds|
        described_class::Record.new(provider: "claude", model: "m", bucket: "ruby_rails", concept: "n_plus_one", mode: :sequential,
                                    seconds: seconds, outcome: seconds == 40 ? :timeout : :ok, tokens_in: 1, tokens_out: 1, attempts: 1)
      end

      expect(calibration.summary(records)).to eq(
        sequential: { n: 5, min: 10, median: 40, p90: over, max: over, timeouts: 1, failures: 0, over_deployed: 1 }
      )
    end
  end
end
