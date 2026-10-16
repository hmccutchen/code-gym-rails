require "rails_helper"

# Rebaseline with UPDATE_REQUEST_SNAPSHOTS=1 only when a request-shape change is the intended deliverable.
RSpec.describe "provider request characterization" do
  REQUEST_SNAPSHOT_DIR = Rails.root.join("spec/fixtures/request_snapshots").freeze
  REQUEST_SNAPSHOT_PROVIDERS = [ ClaudeService, GeminiService, OpenaiService ].freeze
  REQUEST_SNAPSHOT_HISTORY = [ { role: "user", content: "FIRST" }, { role: "assistant", content: "REPLY" } ].freeze

  # Named for the purpose behind each shape, so a failure maps back to a caller.
  KEYWORD_SHAPES = {
    "plain"                 => {},
    "cache_system"          => { cache_system: true },
    "long_read_timeout"     => { read_timeout: AiService::GENERATION_READ_TIMEOUT },
    "capped_max_tokens"     => { max_tokens: 250 },
    "routed_generation"     => { purpose: "generate_exercise", read_timeout: AiService::GENERATION_READ_TIMEOUT }
  }.freeze

  # Each purpose's per-call values; its settings come from CALL_PROFILES, so a snapshot proves the profile matches its call site.
  PURPOSE_SHAPES = {
    "generate_exercise"           => {},
    "generate_exercise_blocking"  => { blocking: true },
    "retry_section"               => {},
    "review_response"             => {},
    "assess_difficulty"           => {},
    "generate_concept_reference"  => {},
    "generate_recognition_guide"  => {},
    "explain_concept_differently" => {},
    "explain_differently"         => {},
    "review_follow_up"            => { history: REQUEST_SNAPSHOT_HISTORY },
    "duck_thread"                 => { history: REQUEST_SNAPSHOT_HISTORY },
    "pseudocode_critique"         => {},
    "pseudocode_translate"        => {},
    "judge_section"               => { response_schema: JudgeVerdict.schema_for(ExerciseSection::CodeReview) },
    "judge_review"                => { response_schema: ReviewProseVerdict.schema }
  }.freeze

  REQUEST_SNAPSHOT_SHAPES = (KEYWORD_SHAPES.keys + PURPOSE_SHAPES.keys.map { |shape| "purpose__#{shape}" }).freeze

  def snapshot_request(shape)
    per_call = { system: "SYSTEM TEXT", prompt: "PROMPT TEXT" }
    return AiService::Request.build(**per_call, **KEYWORD_SHAPES.fetch(shape)) unless shape.start_with?("purpose__")

    purpose_shape = shape.delete_prefix("purpose__")
    AiService.request_for(purpose_shape.delete_suffix("_blocking"), **per_call, **PURPOSE_SHAPES.fetch(purpose_shape))
  end

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

  REQUEST_SNAPSHOT_PROVIDERS.each do |service_class|
    provider = service_class.name.sub("Service", "").downcase

    REQUEST_SNAPSHOT_SHAPES.each do |shape|
      context "#{provider} / #{shape}" do
        let(:body) do
          service, bodies = recording(service_class)
          service.send(:call, snapshot_request(shape))
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

  it "has a purpose shape for every ApiUsage purpose and for nothing else" do
    purposes = PURPOSE_SHAPES.keys.map { |shape| shape.delete_suffix("_blocking") }.uniq
    expect(purposes.sort).to eq(ApiUsage::PURPOSES.sort)
  end

  it "has no snapshot left behind for a shape that no longer exists" do
    expected = REQUEST_SNAPSHOT_PROVIDERS.flat_map { |service_class|
      provider = service_class.name.sub("Service", "").downcase
      REQUEST_SNAPSHOT_SHAPES.map { |shape| snapshot_path(provider, shape).basename.to_s }
    }

    expect(Dir.children(REQUEST_SNAPSHOT_DIR).sort).to eq(expected.sort)
  end
end
