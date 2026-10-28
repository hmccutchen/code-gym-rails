require "rails_helper"
require Rails.root.join("script/key_sample_drafts")

RSpec.describe KeySampleDrafts do
  let(:out)      { StringIO.new }
  let(:usage)    { [] }
  let(:kind)     { ExerciseSection::SecurityReview }
  let(:prompts)  { [] }
  let(:verdicts) { [] }
  let(:service)  { described_class.service("sk-ant-test", usage) }
  let(:dir)      { Dir.mktmpdir }
  let(:path)     { described_class.reserve_out_path!(File.join(dir, "keys.json")) }

  after { FileUtils.rm_rf(dir) }

  def drafts(count: 2, language: "ruby_rails")
    described_class.new(kind: kind, language: language, count: count, service: service, out: out)
  end

  def reject = { "status" => "reject", "principle" => "underdetermined", "evidence" => "e", "reason" => "r" }

  def written = JSON.parse(File.read(path))

  # A single-section retry carries the concept it was asked for, as a provider following the fixed-concept line would.
  before do
    seen, queued = prompts, verdicts
    connection = Faraday.new do |f|
      f.adapter :test do |stub|
        stub.post(ClaudeService::API_URL) do |env|
          body    = JSON.parse(env.body)
          system  = body["system"].is_a?(Array) ? body["system"].first["text"] : body["system"]
          prompt  = body["messages"].last["content"]
          concept = prompt[/concept must be exactly `([^`]+)`/, 1]
          purpose = concept ? "retry_section" : purpose_for(system)
          seen << purpose
          text = FakeService.new("unused").send(:call, AiService.request_for(purpose, system: system, prompt: prompt))[:text]
          if concept
            text = { kind.key => JSON.parse(text).fetch(kind.key).merge("concept" => concept) }.to_json
          elsif purpose == "judge_section" && queued.any?
            text = queued.shift.to_json
          end
          [ 200, {}, { "content" => [ { "type" => "text", "text" => text } ],
                       "usage" => { "input_tokens" => 70, "output_tokens" => 30 } }.to_json ]
        end
      end
    end
    allow_any_instance_of(ClaudeService).to receive(:build_connection).and_return(connection)
  end

  it "drafts each section through the retry and judge routes, and writes key-sheet entries with the judge's outcome" do
    result = drafts.call(path)

    expect(prompts).to eq(%w[retry_section judge_section retry_section judge_section])
    expect(result.entries.size).to eq(2)
    expect(written["sections"].first).to include("kind" => "security_review", "language" => "ruby_rails", "judge" => "keep",
                                                 "answer_key" => FakeService::EXERCISE_PROBLEM_SET.dig("security_review", "answer_key"))
    expect(written["sections"].first["shown"]).to eq("snippet" => FakeService::EXERCISE_PROBLEM_SET.dig("security_review", "snippet"))
  end

  it "pitches the kept sections at each rung in turn and meets every concept at every rung" do
    entries = drafts(count: 8).call(path).entries

    expect(entries.map { |entry| entry["rung"] }).to eq(KindDifficulty::LEVELS * 2)
    expect(entries.map { |entry| entry.values_at("rung", "concept") }.uniq.size).to eq(8)
  end

  it "gives a rejected draft's rung to the next draft, so a rejection doesn't skip a rung" do
    verdicts.push(reject)

    expect(drafts(count: 1).call(path).entries.sole["rung"]).to eq(KindDifficulty::LEVELS.first)
  end

  it "writes no day, response, usage row or suggested concept, inside a read-only transaction" do
    allow(ReviewBaselineExport).to receive(:read_only).and_call_original

    expect { drafts.call(path) }.not_to change { [ DailyExercise.count, DailyResponse.count, ApiUsage.count, SuggestedConcept.count ] }
    expect(ReviewBaselineExport).to have_received(:read_only)
    expect(usage.size).to eq(4)
  end

  it "leaves out a rejected draft and drafts another, within the attempt cap" do
    verdicts.push(reject)

    result = drafts(count: 1).call(path)

    expect(result.entries.size).to eq(1)
    expect(result.rejected).to eq(1)
    expect(prompts.count("retry_section")).to eq(2)
  end

  it "stops at the attempt cap when every draft is rejected" do
    verdicts.push(*Array.new(4) { reject })

    expect(drafts(count: 1).call(path).entries).to be_empty
    expect(prompts.count("retry_section")).to eq(described_class::ATTEMPTS_PER_SECTION)
  end

  it "applies a judge's prose edit, as a judged day would ship it" do
    verdicts.push({ "status" => "edit", "issues" => [ { "type" => "padding", "evidence" => "e" } ],
                    "fields" => { "question" => "Edited question?" } })

    expect(drafts(count: 1).call(path).entries.sole).to include("judge" => "edit", "question" => "Edited question?")
  end

  it "counts a draft whose key ingest dropped, and leaves it out without judging it" do
    allow(kind).to receive(:normalize_planted_key).and_return(nil)

    result = drafts(count: 1).call(path)

    expect(result.keyless).to eq(described_class::ATTEMPTS_PER_SECTION)
    expect(result.entries).to be_empty
    expect(prompts).not_to include("judge_section")
  end

  [ ProviderError::InvalidResponseError.new("bad"), Timeout::Error.new("slow") ].each do |error|
    it "counts a draft that fails with #{error.class}, and keeps going" do
      calls = 0
      allow(service).to receive(:judge_section).and_wrap_original do |original, *args, **options|
        (calls += 1) == 1 ? raise(error) : original.call(*args, **options)
      end

      result = drafts(count: 1).call(path)

      expect(result.failed).to eq([ "#{error.class}: #{error.message}" ])
      expect(result.entries.size).to eq(1)
    end
  end

  it "keeps every section already drafted when the run is interrupted" do
    calls = 0
    allow(service).to receive(:judge_section).and_wrap_original do |original, *args, **options|
      (calls += 1) == 2 ? raise(Interrupt) : original.call(*args, **options)
    end

    expect { drafts(count: 3).call(path) }.to raise_error(Interrupt)
    expect(written["sections"].size).to eq(1)
  end

  it "prints a plan with the draft count, the most calls and a cost bound, and makes no call" do
    drafts(count: 3).plan

    expect(prompts).to be_empty
    expect(out.string).to include("security_review", "3 sections", "at most 12 calls", "$")
  end

  it "measures the plan's retry input from the prompt a real retry sends, ladders included" do
    sent = []
    plan = DailyPlan.for(User.new, language: "ruby_rails")
    allow(DailyPlan).to receive(:for).and_return(plan)
    allow_any_instance_of(ClaudeService).to receive(:request_body).and_wrap_original do |original, request|
      sent << "#{request.system}#{request.prompt}" if request.purpose == "retry_section"
      original.call(request)
    end

    measured = drafts.send(:retry_input_tokens, KindDifficulty::LEVELS.first)
    drafts(count: 1).call(path)

    expect(measured).to eq(sent.first.size / described_class::APPROX_CHARS_PER_TOKEN)
  end

  it "drafts only the three kinds read from drafts" do
    expect(described_class::KINDS).to all(satisfy(&:planted_key?))
    [ ExerciseSection::CodeReview, ExerciseSection::Pattern ].each do |other|
      expect { described_class.new(kind: other, language: "ruby_rails", count: 1, service: service, out: out) }
        .to raise_error(ArgumentError, /isn't drafted/)
    end
  end

  it "refuses to run in production" do
    expect { described_class.refuse_production!(ActiveSupport::EnvironmentInquirer.new("production")) }
      .to raise_error(ArgumentError, /never in production/)
    expect(described_class.refuse_production!(ActiveSupport::EnvironmentInquirer.new("development"))).to be_nil
  end

  it "reserves a new output file outside the repository before any call" do
    expect(path).to eq(File.join(File.realpath(dir), "keys.json"))
    expect(File).to exist(path)
    expect { described_class.reserve_out_path!(path) }.to raise_error(ArgumentError, /already exists/)
    expect { described_class.reserve_out_path!(File.join(dir, "missing", "keys.json")) }.to raise_error(ArgumentError, /No directory/)
    expect { described_class.reserve_out_path!(Rails.root.join("tmp/keys.json").to_s) }.to raise_error(ArgumentError, /outside/)
  end

  it "refuses a path that reaches the repository through a symlink" do
    File.symlink(Rails.root.join("tmp").to_s, File.join(dir, "link"))

    expect { described_class.reserve_out_path!(File.join(dir, "link", "keys.json")) }.to raise_error(ArgumentError, /outside/)
  end

  it "prices the run from the routes the service calls, and says so when no call was made" do
    drafts(count: 1).call(path)

    expect(drafts.cost_line(usage)).to match(%r{\A2 calls · 140 in / 60 out · \$\d+\.\d\d\z})
    expect(drafts.cost_line([])).to eq("no calls made")
  end
end
