require "rails_helper"

# Pins the exact JSON body each provider posts, for each keyword shape the
# single-shot purposes actually use — not every combination `#call` accepts,
# and deliberately not `history:` itself, whose whole point here is that it
# never reaches these callers.
#
# This exists to guard the addition of a `history:` keyword to the shared
# `#call` interface. That addition must change nothing about the request any
# non-conversational caller produces, and "nothing" includes key order: both
# bodies are built by literal Hash construction and serialized with #to_json,
# so a reordered or conditionally-inserted key is a visible diff here.
#
# Deliberately at the #call boundary rather than through AiService's public
# methods: #generate_exercise routes through DailyPlan.for, which
# reads the database and rolls WeightedRoll, so its body cannot be snapshotted
# without stubbing the very decision under test. What each public method passes
# down is covered by spec/services/ai_service_spec.rb (see the "single-shot
# purposes" group, which pins the roster of purpose names — the single-shot
# purposes plus "review_follow_up" and "duck_thread", asserted by name so a
# missed one fails loudly instead of by silent subtraction — and then drives
# every public entry point behind them to assert the history it reaches
# #call with is empty, which is the caller-level half this file cannot state);
# the prompt text they build is covered byte-for-byte by
# spec/services/generation_prompt_characterization_spec.rb.
#
# Rebaselining: UPDATE_REQUEST_SNAPSHOTS=1 bundle exec rspec <this file>.
# Do that only when a request-shape change is the intended deliverable.
# Rebaselining while adding `history:` would pin the new behavior and defeat
# the entire point of this file.
RSpec.describe "provider request characterization" do
  REQUEST_SNAPSHOT_DIR = Rails.root.join("spec/fixtures/request_snapshots").freeze

  # The distinct keyword shapes the single-shot purposes actually use.
  # Named for the purpose that motivates each, so a reader can map a failure
  # back to a caller.
  KEYWORD_SHAPES = {
    "plain"                 => {},
    "cache_system"          => { cache_system: true },
    "long_read_timeout"     => { read_timeout: AiService::GENERATION_READ_TIMEOUT },
    "capped_max_tokens"     => { max_tokens: 250 }
  }.freeze

  # Captures the posted body without a network call. Returns [service, bodies].
  def recording(service_class)
    bodies = []
    service = service_class.new("test-key")
    conn = Faraday.new do |f|
      f.adapter :test do |stub|
        stub.post(service_class::API_URL) do |env|
          bodies << env.body
          [ 200, {}, success_body_for(service_class) ]
        end
      end
    end
    service.instance_variable_set(:@conn, conn)
    [ service, bodies ]
  end

  def success_body_for(service_class)
    if service_class == ClaudeService
      { "content" => [ { "type" => "text", "text" => "ok" } ],
        "usage" => { "input_tokens" => 1, "output_tokens" => 1 } }.to_json
    else
      { "steps" => [ { "type" => "model_output", "content" => [ { "type" => "text", "text" => "ok" } ] } ],
        "usage" => { "total_input_tokens" => 1, "total_output_tokens" => 1 } }.to_json
    end
  end

  def snapshot_path(provider, shape)
    REQUEST_SNAPSHOT_DIR.join("#{provider}__#{shape}.json")
  end

  [ ClaudeService, GeminiService ].each do |service_class|
    provider = service_class.name.sub("Service", "").downcase

    KEYWORD_SHAPES.each do |shape, kwargs|
      context "#{provider} / #{shape}" do
        let(:body) do
          service, bodies = recording(service_class)
          service.send(:call, system: "SYSTEM TEXT", prompt: "PROMPT TEXT", **kwargs)
          raise "expected exactly one request, got #{bodies.size}" unless bodies.size == 1

          # Re-serialized with indentation so a diff is readable line by line,
          # while still failing on any key-order change.
          JSON.pretty_generate(JSON.parse(bodies.first))
        end

        let(:path) { snapshot_path(provider, shape) }

        it "matches its recorded snapshot byte for byte" do
          if ENV["UPDATE_REQUEST_SNAPSHOTS"]
            FileUtils.mkdir_p(REQUEST_SNAPSHOT_DIR)
            File.write(path, body)
          end

          expect(path).to exist,
            "No snapshot at #{path.relative_path_from(Rails.root)}. " \
            "Record it against unmodified code with UPDATE_REQUEST_SNAPSHOTS=1."

          expect(body).to eq(File.read(path))
        end
      end
    end
  end

  it "has no snapshot left behind for a shape that no longer exists" do
    expected = [ ClaudeService, GeminiService ].flat_map { |service_class|
      provider = service_class.name.sub("Service", "").downcase
      KEYWORD_SHAPES.keys.map { |shape| snapshot_path(provider, shape).basename.to_s }
    }

    expect(Dir.children(REQUEST_SNAPSHOT_DIR).sort).to eq(expected.sort)
  end
end
