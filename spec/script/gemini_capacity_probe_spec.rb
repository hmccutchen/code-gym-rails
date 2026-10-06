require "rails_helper"
require Rails.root.join("script/gemini_capacity_probe")

# Drives the probe against a stubbed Gemini that answers every production
# prompt the way FakeService does, so a whole tester-day runs through the
# real entry points, then refuses with a stored 429 body.
RSpec.describe GeminiCapacityProbe, type: :model do
  let(:user) { create_user_with_key(time_zone: "America/New_York").tap { |u| u.update!(provider: "gemini", api_keys: { "gemini" => "AIzaProbe" }) } }
  let(:out) { StringIO.new }
  let(:output_dir) { Dir.mktmpdir("gemini-probe") }
  let(:sleeps) { [] }
  let(:zones) { [] }
  let(:posted) { [] }
  let(:refuse_after) { nil }

  after { FileUtils.remove_entry(output_dir) }

  def reply(text)
    { "steps" => [ { "type" => "model_output", "content" => [ { "type" => "text", "text" => text } ] } ],
      "usage" => { "total_input_tokens" => 120, "total_output_tokens" => 40, "total_thought_tokens" => 10, "total_cached_tokens" => 0 } }.to_json
  end

  def refusal
    Rails.root.join("spec/fixtures/provider_errors/gemini_429_daily.json").read
  end

  # Each request is answered with FakeService's canned reply for the prompt
  # it carries, until the refusal point.
  def stubs
    fake = FakeService.new("fake")
    Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post(GeminiService::API_URL) do |env|
        body = JSON.parse(env.body)
        posted << body
        if refuse_after && posted.size > refuse_after
          [ 429, { "retry-after" => "39" }, refusal ]
        else
          [ 200, {}, reply(fake.send(:call, system: body["system_instruction"], prompt: body["input"])[:text]) ]
        end
      end
    end
  end

  def probe(**options)
    described_class.new(api_key: "AIzaProbe", user: user, out: out, output_dir: output_dir,
                        adapter: [ :test, stubs ], sleeper: ->(seconds) { sleeps << seconds; zones << Time.zone.name }, **options)
  end

  it "replays one tester-day through the production prompts in order, paced between steps" do
    records = probe(max_days: 1).run

    expect(records.map(&:step)).to eq([
      "draft", "judge code_review", "judge design_comparison",
      "review (2 grading + difficulty) [1]", "review (2 grading + difficulty) [2]", "review (2 grading + difficulty) [3]",
      "reference n_plus_one", "duck turn 1", "duck turn 2", "duck turn 3"
    ])
    expect(records.size).to eq(described_class.calls_per_day)
    expect(records).to all(have_attributes(status: 200, input_tokens: 120, output_tokens: 40, thought_tokens: 10, error: nil))
    expect(posted.first["model"]).to eq(GeminiService::DEFAULT_ROUTE[:model])
    expect(posted.map { |body| body["model"] }.uniq).to eq([ GeminiService::DEFAULT_ROUTE[:model] ])
    expect(sleeps).to eq([ 15, 15, 45, 45, 15, 15, 15 ])
    expect(zones.uniq).to eq([ "America/New_York" ])
    expect(out.string).to include("Tokens per completed tester-day: {1=>1700}").and include("Largest single request: 120 input tokens")
  end

  # The review sends its three calls together, so pacing once per step would
  # land six requests in one rolling minute; the waits around a fan-out keep
  # every minute under a 5 RPM limit.
  it "keeps every rolling minute within five requests at the default pace" do
    records = probe(max_days: 1).run

    times = []
    clock = 0
    waits = sleeps.dup
    records.map { |r| r.step.sub(/ \[\d+\]\z/, "") }.chunk_while { |a, b| a == b }.each_with_index do |step, index|
      clock += waits.shift if index.positive?
      step.size.times { times << clock }
    end
    expect(times.size).to eq(described_class.calls_per_day)
    times.each { |start| expect(times.count { |t| t >= start && t < start + 60 }).to be <= 5 }
  end

  it "waits for a reply still on the wire before reading a step's attempts" do
    log = described_class::AttemptLog.new
    log.start!
    log.start!
    log.record(status: 200)
    Thread.new { sleep 0.2; log.record(status: 429) }

    expect(log.drain(timeout: 5).map { |a| a[:status] }).to eq([ 200, 429 ])
    expect(log.in_flight).to eq(0)

    log.start!
    log.abandon!
    expect(log.drain(timeout: 1)).to eq([])
  end

  it "writes one file per refused reply and leaves out a body that can echo the key" do
    fake = FakeService.new("fake")
    refusing = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post(GeminiService::API_URL) do |env|
        body = JSON.parse(env.body)
        posted << body
        case posted.size
        when 1 then [ 200, {}, reply(fake.send(:call, system: body["system_instruction"], prompt: body["input"])[:text]) ]
        when 2 then [ 400, {}, Rails.root.join("spec/fixtures/provider_errors/gemini_400_api_key_invalid.json").read.sub("API key not valid", "AIzaProbe is not valid") ]
        else [ 503, {}, "<html>down</html>" ]
        end
      end
    end
    described_class.new(api_key: "AIzaProbe", user: user, out: out, output_dir: output_dir,
                        adapter: [ :test, refusing ], sleeper: ->(_) { }, max_days: 1).run

    captures = Dir[File.join(output_dir, "*.json")].sort
    expect(captures.size).to be >= 4
    expect(captures.count { |path| path.end_with?("-400.json") }).to eq(1)
    expect(captures.count { |path| path.end_with?("-503.json") }).to be >= 3
    rejected = File.read(captures.find { |path| path.end_with?("-400.json") })
    expect(rejected).to include("omitted")
    expect(rejected).not_to include("AIzaProbe")
  end

  it "plans a two-section day without changing the stored setting" do
    user.update!(daily_section_count: 4)
    probe(max_days: 1).run

    expect(user.reload.daily_section_count).to eq(4)
    expect(posted.first["input"]).to include("code_review").and include("design_comparison")
  end

  context "when the provider refuses partway through the second day" do
    let(:refuse_after) { 12 }

    it "stops at the first 429, names the quota and the delay, writes the body, and sizes the quota day" do
      records = probe.run

      expect(records.count(&:rate_limited?)).to eq(1)
      hit = records.find(&:rate_limited?)
      expect(hit).to have_attributes(day: 2, quota_id: "GenerateRequestsPerDayPerProjectPerModel-FreeTier", quota_value: "20",
                                     retry_delay: "39s", retry_after: "39")
      expect(records.size).to eq(13)
      expect(out.string).to include("First 429 on request 13: per-day limit (quotaId=GenerateRequestsPerDayPerProjectPerModel-FreeTier, quotaValue=20).")
      expect(out.string).to include("Tester-days per quota day: 2.")
      expect(out.string).to include("Tokens per completed tester-day: {1=>1700}")

      captures = Dir[File.join(output_dir, "*-429.json")]
      expect(captures.size).to eq(1)
      capture = JSON.parse(File.read(captures.first))
      expect(capture["status"]).to eq(429)
      expect(capture["headers"]).to include("retry-after" => "39")
      expect(capture.to_json).not_to include("AIzaProbe")
      expect(File.read(File.join(output_dir, described_class::FIXTURE_CAPTURE))).to eq(refusal)
    end
  end

  context "when the 429 lands inside the review fan-out, which raises nothing of its own" do
    let(:refuse_after) { 4 }

    it "still stops the run" do
      records = probe.run

      expect(records.count(&:rate_limited?)).to be >= 1
      expect(records.map(&:step)).not_to include(a_string_starting_with("reference"))
    end
  end

  it "writes no usage rows and no exercise, response or reference" do
    probe(max_days: 1).run

    expect([ ApiUsage.count, DailyExercise.count, DailyResponse.count, ConceptReference.count ]).to eq([ 0, 0, 0, 0 ])
  end

  it "records a reply the app could not use and goes on" do
    fake = FakeService.new("fake")
    broken = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post(GeminiService::API_URL) do |env|
        body = JSON.parse(env.body)
        if body["system_instruction"].to_s.include?("writing a concise, durable reference")
          [ 200, {}, reply("not json") ]
        else
          [ 200, {}, reply(fake.send(:call, system: body["system_instruction"], prompt: body["input"])[:text]) ]
        end
      end
    end
    records = described_class.new(api_key: "AIzaProbe", user: user, out: out, output_dir: output_dir,
                                  adapter: [ :test, broken ], sleeper: ->(_) { }, max_days: 1).run

    reference = records.find { |r| r.step.start_with?("reference") }
    expect(reference.status).to eq(200)
    expect(reference.error).to start_with("InvalidResponseError")
    expect(records.last.step).to eq("duck turn 3")
  end
end
