require "rails_helper"

# Rebaseline with UPDATE_REQUEST_SNAPSHOTS=1 only when a request-shape change is the intended deliverable.
RSpec.describe "provider request characterization" do
  REQUEST_SNAPSHOT_DIR = Rails.root.join("spec/fixtures/request_snapshots").freeze

  # Named for the purpose behind each shape, so a failure maps back to a caller.
  KEYWORD_SHAPES = {
    "plain"                 => {},
    "cache_system"          => { cache_system: true },
    "long_read_timeout"     => { read_timeout: AiService::GENERATION_READ_TIMEOUT },
    "capped_max_tokens"     => { max_tokens: 250 },
    "routed_generation"     => { purpose: "generate_exercise", read_timeout: AiService::GENERATION_READ_TIMEOUT }
  }.freeze

  # Captures the posted body without a network call. Returns [service, bodies].
  def recording(service_class)
    bodies = []
    service = service_class.new("test-key")
    conn = Faraday.new do |f|
      f.adapter :test do |stub|
        stub.post(service_class::API_URL) do |env|
          bodies << env.body
          [ 200, {}, provider_success_body(service_class) ]
        end
      end
    end
    service.instance_variable_set(:@conn, conn)
    [ service, bodies ]
  end

  def snapshot_path(provider, shape)
    REQUEST_SNAPSHOT_DIR.join("#{provider}__#{shape}.json")
  end

  [ ClaudeService, GeminiService, OpenaiService ].each do |service_class|
    provider = service_class.name.sub("Service", "").downcase

    KEYWORD_SHAPES.each do |shape, kwargs|
      context "#{provider} / #{shape}" do
        let(:body) do
          service, bodies = recording(service_class)
          service.send(:call, system: "SYSTEM TEXT", prompt: "PROMPT TEXT", **kwargs)
          raise "expected exactly one request, got #{bodies.size}" unless bodies.size == 1

          # Pretty-printed so a diff reads line by line while still failing on key order.
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
    expected = [ ClaudeService, GeminiService, OpenaiService ].flat_map { |service_class|
      provider = service_class.name.sub("Service", "").downcase
      KEYWORD_SHAPES.keys.map { |shape| snapshot_path(provider, shape).basename.to_s }
    }

    expect(Dir.children(REQUEST_SNAPSHOT_DIR).sort).to eq(expected.sort)
  end
end
