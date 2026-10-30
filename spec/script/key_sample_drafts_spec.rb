require "rails_helper"
require Rails.root.join("script/key_sample_drafts")

RSpec.describe KeySampleDrafts do
  let(:out)      { StringIO.new }
  let(:usage)    { [] }
  let(:kind)     { ExerciseSection::SecurityReview }
  let(:prompts)  { [] }
  let(:verdicts) { [] }
  let(:solves)   { [] }
  let(:bodies)   { [] }
  let(:planted)  { nil }
  let(:service)  { described_class.service("sk-ant-test", usage) }
  let(:dir)      { Dir.mktmpdir }
  let(:path)     { described_class.reserve_out_path!(File.join(dir, "keys.json")) }

  after { FileUtils.rm_rf(dir) }

  def drafts(count: 2, language: "ruby_rails", triage: false)
    described_class.new(kind: kind, language: language, count: count, service: service, out: out, triage: triage)
  end

  def reject = { "status" => "reject", "principle" => "underdetermined", "evidence" => "e", "reason" => "r" }

  def written = JSON.parse(File.read(path))

  # A single-section retry carries the concept it was asked for, as a provider following the fixed-concept line would.
  before do
    seen, queued, solved, sent, key = prompts, verdicts, solves, bodies, planted
    connection = Faraday.new do |f|
      f.adapter :test do |stub|
        stub.post(ClaudeService::API_URL) do |env|
          sent << env.body
          body    = JSON.parse(env.body)
          system  = body["system"].is_a?(Array) ? body["system"].first["text"] : body["system"]
          prompt  = body["messages"].last["content"]
          concept = prompt[/concept must be exactly `([^`]+)`/, 1]
          purpose = concept ? "retry_section" : (system == KeyTriage::SYSTEM ? KeyTriage::PURPOSE : purpose_for(system))
          seen << purpose
          if purpose == KeyTriage::PURPOSE
            text = (solved.shift || { "issue" => FakeService::EXERCISE_PROBLEM_SET.dig("code_review", "answer_key", "issue"), "fix" => "f" }).to_json
          else
            text = FakeService.new("unused").send(:call, AiService.request_for(purpose, system: system, prompt: prompt))[:text]
          end
          if concept
            drafted = JSON.parse(text).fetch(kind.key).merge("concept" => concept)
            drafted["answer_key"] = key if key
            text = { kind.key => drafted }.to_json
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

  context "with --triage" do
    let(:kind) { ExerciseSection::CodeReview }
    let(:key_issue) { FakeService::EXERCISE_PROBLEM_SET.dig("code_review", "answer_key", "issue") }

    def triage(count: 3) = drafts(count: count, triage: true)

    it "solves each kept section after its judge, and writes the outcome, mode and solver reply" do
      result = triage(count: 1).call(path)

      expect(prompts).to eq([ "retry_section", "judge_section", KeyTriage::PURPOSE ])
      expect(result.entries.sole).to include("code_review_mode" => "application_code", "triage" => "agree", "key_lines" => { "snippet" => [ "2" ] },
                                             "solver" => { "issue" => key_issue, "fix" => "f" })
    end

    it "cycles the modes across a 30-section run, each draft toy and single-file with a concept from its mode's vocabulary" do
      plans = []
      allow(ForcedConceptDrafts).to receive(:rung_draft).and_wrap_original do |original, *args, **options|
        plans << options[:plan]
        original.call(*args, **options)
      end

      entries = triage(count: 30).call(path).entries

      expect(entries.map { |entry| entry["code_review_mode"] }).to eq(KeyTriage::MODES.map(&:to_s) * 10)
      expect(plans.map(&:code_review_mode).tally.values).to all(be >= 10)
      expect(plans.map { |plan| [ plan.code_review_source, plan.code_review_files ] }.uniq).to eq([ [ nil, :single ] ])
      entries.each do |entry|
        vocabulary = ConceptVocabulary.selectable_for_section("code_review", "ruby_rails", mode: entry["code_review_mode"].to_sym, rung: entry["rung"])
        expect(vocabulary).to include(entry["concept"])
      end
    end

    context "with a sentinel in every answer-key field" do
      let(:planted) { %w[issue why_it_matters fix].index_with { |field| "SENTINEL-#{field} `customer.orders.sum(&:total_cents)`" } }

      it "never sends a key to the draft, the judge or the solve" do
        result = triage(count: 2).call(path)

        expect(result.entries.size).to eq(2)
        expect(result.entries.first["answer_key"].values.join).to include("SENTINEL")
        expect(bodies.size).to eq(6)
        expect(bodies).to all(satisfy { |body| !body.include?("SENTINEL") })
      end
    end

    it "writes every disagreement and unlocated section and one agreement per mode, and names a mode with none" do
      solves.push({ "issue" => key_issue, "fix" => "f" }, { "issue" => "`customers.each { |c| puts loyalty_tier(c) }`", "fix" => "f" },
                  { "issue" => "nothing quoted", "fix" => "f" })

      run    = triage(count: 3)
      result = run.call(path)

      expect(written["sections"].map { |entry| entry["triage"] }).to eq(%w[disagree unlocated agree])
      expect(written["summary"].last).to eq("no agreement to read for: test_file, schema_review")
      expect(run.summary(result).first).to eq("triage: agree 1 · disagree 1 · unlocated 1")
      expect(prompts.count(KeyTriage::PURPOSE)).to eq(3)
    end

    it "counts a solve that fails, and leaves its section out" do
      solves.push({ "issue" => "no fix" })

      result = triage(count: 1).call(path)

      expect(result.failed.sole).to start_with("ProviderError::InvalidResponseError")
      expect(result.entries.size).to eq(1)
    end

    it "routes the solve to the solver model at its pinned effort, Sonnet 5.5 unless another solver model is named" do
      triage(count: 1).call(path)
      expect(JSON.parse(bodies.last)).to include("model" => "claude-sonnet-5-5", "output_config" => include("effort" => "high"))

      bodies.clear
      opus = described_class.service("sk-ant-test", usage, solver_model: "claude-opus-5-5")
      described_class.new(kind: kind, language: "ruby_rails", count: 1, service: opus, out: out, triage: true).call(path)
      expect(JSON.parse(bodies.last)).to include("model" => "claude-opus-5-5", "output_config" => include("effort" => "high"))
      expect { described_class.service("sk-ant-test", usage, solver_model: "claude-haiku-4-5") }.to raise_error(ArgumentError, /solver model/)
    end

    it "prints a plan that counts the solve calls, and makes no call" do
      triage(count: 3).plan

      expect(prompts).to be_empty
      expect(out.string).to include("each kept one solved", "at most 18 calls", "$")
    end

    it "is the only way code_review is drafted, and drafts nothing else" do
      expect { drafts(count: 1) }.to raise_error(ArgumentError, /isn't drafted/)
      expect { described_class.new(kind: ExerciseSection::SecurityReview, language: "ruby_rails", count: 1, service: service, out: out, triage: true) }
        .to raise_error(ArgumentError, /code_review only/)
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
