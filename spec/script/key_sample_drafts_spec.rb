require "rails_helper"
require Rails.root.join("script/key_sample_drafts")

RSpec.describe KeySampleDrafts do
  let(:out)     { StringIO.new }
  let(:usage)   { [] }
  let(:kind)    { ExerciseSection::SecurityReview }
  let(:prompts) { [] }
  let(:verdicts) { [] }
  let(:service) { described_class.service("sk-ant-test", usage) }

  def drafts(count: 2, language: "ruby_rails")
    described_class.new(kind: kind, language: language, count: count, service: service, out: out)
  end

  def verdict(status)
    { "status" => status, "principle" => "underdetermined", "evidence" => "e", "reason" => "r" }
  end

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

  it "drafts each section through the retry and judge routes, and returns key-sheet entries with the judge's outcome" do
    result = drafts.call

    expect(prompts).to eq(%w[retry_section judge_section retry_section judge_section])
    expect(result.entries.size).to eq(2)
    expect(result.entries.first).to include("kind" => "security_review", "language" => "ruby_rails", "judge" => "keep",
                                            "answer_key" => FakeService::EXERCISE_PROBLEM_SET.dig("security_review", "answer_key"))
    expect(result.entries.first["shown"]).to eq("snippet" => FakeService::EXERCISE_PROBLEM_SET.dig("security_review", "snippet"))
  end

  it "fixes a different concept and rung for each draft, from the kind's selectable vocabulary" do
    result = drafts(count: 2).call

    rungs = KindDifficulty::LEVELS.first(2)
    expect(result.entries.map { |entry| entry["rung"] }).to eq(rungs)
    expect(result.entries.map { |entry| entry["concept"] })
      .to eq(rungs.each_with_index.map { |rung, index| described_class.concepts_for(kind, "ruby_rails", rung)[index % 2] })
  end

  it "writes no day, response, usage row or suggested concept" do
    expect { drafts.call }.not_to change { [ DailyExercise.count, DailyResponse.count, ApiUsage.count, SuggestedConcept.count ] }
    expect(usage.size).to eq(4)
  end

  it "leaves out a rejected draft and drafts another, within the attempt cap" do
    verdicts.push(verdict("reject"))

    result = drafts(count: 1).call

    expect(result.entries.size).to eq(1)
    expect(result.rejected).to eq(1)
    expect(prompts.count("retry_section")).to eq(2)
  end

  it "stops at the attempt cap when every draft is rejected" do
    verdicts.push(*Array.new(4) { verdict("reject") })

    result = drafts(count: 1).call

    expect(result.entries).to be_empty
    expect(prompts.count("retry_section")).to eq(described_class::ATTEMPTS_PER_SECTION)
  end

  it "applies a judge's prose edit, as a judged day would ship it" do
    verdicts.push({ "status" => "edit", "issues" => [ { "type" => "padding", "evidence" => "e" } ],
                    "fields" => { "question" => "Edited question?" } })

    expect(drafts(count: 1).call.entries.sole).to include("judge" => "edit", "question" => "Edited question?")
  end

  it "counts a draft whose key ingest dropped, and leaves it out without judging it" do
    allow(kind).to receive(:normalize_planted_key).and_return(nil)

    result = drafts(count: 1).call

    expect(result.keyless).to eq(described_class::ATTEMPTS_PER_SECTION)
    expect(result.entries).to be_empty
    expect(prompts).not_to include("judge_section")
  end

  it "counts a draft the provider fails, and keeps going" do
    calls = 0
    allow(service).to receive(:judge_section).and_wrap_original do |original, *args, **options|
      (calls += 1) == 1 ? raise(ProviderError::InvalidResponseError, "bad") : original.call(*args, **options)
    end

    result = drafts(count: 1).call

    expect(result.failed).to eq([ "ProviderError::InvalidResponseError: bad" ])
    expect(result.entries.size).to eq(1)
  end

  it "prints a plan with the draft count, the most calls and an upper-bound cost, and makes no call" do
    drafts(count: 3).plan

    expect(prompts).to be_empty
    expect(out.string).to include("security_review", "3 sections", "at most 12 calls", "$")
  end

  it "refuses a kind that plants no key" do
    expect { described_class.new(kind: ExerciseSection::Pattern, language: "ruby_rails", count: 1, service: service, out: out) }
      .to raise_error(ArgumentError, /plants no key/)
  end

  it "refuses an output path inside the repository or one that already exists" do
    expect { described_class.check_out_path!(Rails.root.join("tmp/keys.json").to_s) }.to raise_error(ArgumentError, /outside/)

    Dir.mktmpdir do |dir|
      taken = File.join(dir, "keys.json").tap { |path| File.write(path, "{}") }
      expect { described_class.check_out_path!(taken) }.to raise_error(ArgumentError, /already exists/)
      expect(described_class.check_out_path!(File.join(dir, "new.json"))).to be_nil
    end
  end

  it "writes the entries and counts to the output file" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "keys.json")
      drafts(count: 1).write(drafts(count: 1).call, path)

      expect(JSON.parse(File.read(path))).to include("sections" => [ include("kind" => "security_review") ],
                                                     "rejected" => 0, "keyless" => 0, "failed" => [])
    end
  end
end
