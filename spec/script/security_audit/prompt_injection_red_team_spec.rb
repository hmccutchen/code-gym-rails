require "rails_helper"
require Rails.root.join("script/security_audit/prompt_injection_red_team")

RSpec.describe PromptInjectionRedTeam do
  let(:out) { StringIO.new }
  let(:posted) { [] }
  let(:keys_used) { [] }

  # Answers in Anthropic's response shape so every case's real prompt building and parsing runs end to end.
  before do
    requests = posted
    keys = keys_used
    connection = Faraday.new do |f|
      f.adapter :test do |stub|
        stub.post(ClaudeService::API_URL) do |env|
          body   = JSON.parse(env.body)
          system = body["system"].is_a?(Array) ? body["system"].first["text"] : body["system"]
          requests << { body: body, system: system }
          text = FakeService.new("unused").send(:call, system: system, prompt: body["messages"].last["content"])[:text]
          [ 200, {}, { "content" => [ { "type" => "text", "text" => text } ],
                       "usage" => { "input_tokens" => 70, "output_tokens" => 30 } }.to_json ]
        end
      end
    end
    allow_any_instance_of(ClaudeService).to receive(:build_connection) do |service|
      keys << service.instance_variable_get(:@api_key)
      connection
    end
  end

  def run_red_team = described_class.new(api_key: "sk-ant-runner", out: out).run

  it "runs every review, judge and duck case and prints a result line for each" do
    run_red_team

    expect(out.string).to include("=== review (#{described_class::REVIEW_ROUTE[:model]})",
                                  "=== judge (#{described_class::JUDGE_ROUTE[:model]})",
                                  "=== duck (#{described_class::DUCK_ROUTE[:model]})")
    %w[baseline\ miss rubric\ override fake\ JSON answer-key\ request].each do |label|
      expect(out.string).to match(/^  #{Regexp.escape(label)}\s+rating \w+ · missed \d+/)
    end
    expect(out.string.scan(/expected reject · got \S+/).size).to eq(3)
    expect(out.string.scan(/no key entry quoted|key entries quoted/).size).to eq(4)
    expect(out.string).not_to include("error:", "invalid:")
  end

  it "bills the runner's key and writes no ApiUsage rows" do
    expect { run_red_team }.not_to change(ApiUsage, :count)

    expect(posted).not_to be_empty
    expect(keys_used.uniq).to eq([ "sk-ant-runner" ])
  end

  # Only provider-written section text still carries tag characters, and ProblemSetIngest is that boundary.
  it "strips the hidden tag characters out of everything the engineer typed (finding A2)" do
    run_red_team

    tagged = posted.select { |request| request[:body].to_json.match?(/[\u{E0000}-\u{E007F}]/) }
    expect(tagged.size).to eq(1)
  end

  it "never sends the ambiguity hunt's answer key to the duck" do
    run_red_team

    key = JSON.parse(described_class::CALIBRATION_DIR.join("ambiguity_hunt_workout_export.json").read)
              .dig("section", "planted_ambiguities")
    duck_requests = posted.select { |request| request[:system].match?(/Socratic thinking partner/) }
    expect(duck_requests.size).to eq(3)
    duck_requests.each { |request| expect(request[:body].to_json).not_to include(*key) }
  end
end
