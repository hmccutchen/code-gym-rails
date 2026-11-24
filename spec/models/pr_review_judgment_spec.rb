require "rails_helper"

RSpec.describe "PR Review blind judgment" do
  let(:kind) { ExerciseSection::CodeReview }
  let(:section) do
    {
      "review_variant" => "pr_review", "scenario" => "Show the booking service's availability.",
      "question" => "Explain the result and give your review disposition.",
      "requirements" => [ "When no slot is available, report the unavailable result." ],
      "file_1_path" => "app/services/availability.rb", "file_1_code" => "def available?\n  slots.any?\nend",
      "file_1_changed_lines" => [ 2 ],
      "file_2_path" => "app/controllers/bookings_controller.rb", "file_2_code" => "def status\n  available? ? :open : :unavailable\nend"
    }
  end
  let(:evidence) { [ { "path" => "app/services/availability.rb", "quote" => "slots.any?" } ] }
  let(:behavior) { { "requirement" => 1, "expected" => "true", "observed" => "true" } }
  let(:keep) do
    { "status" => "keep", "case" => "acceptable", "reason" => "The service tests whether a slot exists.",
      "evidence" => evidence, "behavior" => behavior }
  end

  def parse(payload, artifact: section)
    JudgeVerdict.parse(payload, kind: kind, section: artifact)
  end

  it "requests a case and grounded evidence without revealing the generator's case or hidden fields" do
    artifact = section.merge(
      "concept" => "CONCEPT_SENTINEL", "answer_key" => { "case" => "flawed", "reason" => "KEY_SENTINEL" },
      "target" => "TARGET_SENTINEL", "pitched_at" => "RUNG_SENTINEL", "source" => "SOURCE_SENTINEL",
      "answer_scaffold" => [ "SCAFFOLD_SENTINEL" ], "teaching_note" => "NOTE_SENTINEL", "extra" => "EXTRA_SENTINEL"
    )
    request = SectionJudgePrompt.generate(kind: kind, section: artifact, rung: "mid_level", locked: true)
    expect(request.fetch(:prompt)).to include(section.fetch("scenario"), section.fetch("question"), *section.fetch("requirements"),
      "File: app/services/availability.rb", "2 |   slots.any?", "File: app/controllers/bookings_controller.rb")
    expect(request.values.join).not_to match(/SENTINEL|review_variant|answer_key/)
    variants = request.fetch(:response_schema).fetch("anyOf")
    expect(variants.map { |variant| variant.fetch("required") }).to eq([
      %w[status case evidence reason behavior], %w[status case evidence reason behavior issues fields], %w[status principle evidence reason]
    ])
  end

  it "passes the public request through the existing section judge and parses its case" do
    service = FakeService.new("fake-key")
    allow(service).to receive(:call_and_log).and_return(text: keep.to_json)
    expect(service).to receive(:parse_json_object).with(keep.to_json, subject: "code_review verdict", log_raw: false).and_call_original

    verdict = service.judge_section(User.new, kind, section, rung: "mid_level", locked: false)

    expect(verdict).to have_attributes(status: :keep, review_case: "acceptable", evidence: evidence, reason: keep.fetch("reason"))
  end

  it "rejects missing, ungrounded, duplicate or oversized evidence" do
    no_file = [ evidence.first.merge("path" => "app/services/another.rb") ]
    substring = [ evidence.first.merge("quote" => "slots") ]
    invented = [ evidence.first.merge("quote" => "slots.none?") ]
    unexpected = [ evidence.first.merge("line" => 2) ]
    [ nil, [], no_file, substring, invented, unexpected, evidence * 2, evidence * 3 ].each do |invalid|
      expect { parse(keep.merge("evidence" => invalid)) }.to raise_error(JudgeVerdict::Invalid)
    end

    ambiguous = section.merge("file_1_code" => "def available?\n  slots.any?\n  slots.any?\nend")
    expect { parse(keep, artifact: ambiguous) }.to raise_error(JudgeVerdict::Invalid)
  end

  it "requires a known disposition on keep or edit and accepts a closed rejection without one" do
    %w[unclear APPROVE].each do |invalid|
      expect { parse(keep.merge("case" => invalid)) }.to raise_error(JudgeVerdict::Invalid)
    end
    expect { parse(keep.except("case")) }.to raise_error(JudgeVerdict::Invalid)
    rejection = { "status" => "reject", "principle" => "underdetermined", "evidence" => "The shown caller omits its output.",
                  "reason" => "Two plausible outcomes would change the review disposition." }
    expect(parse(rejection)).to have_attributes(status: :reject, principle: "underdetermined", review_case: nil)
    expect { parse(rejection.merge("case" => "acceptable")) }.to raise_error(JudgeVerdict::Invalid)
    expect { parse(rejection.merge("principle" => "material_blocker")) }.to raise_error(JudgeVerdict::Invalid)
  end

  it "requires a behavior observation consistent with the case and a visible requirement" do
    [ nil, behavior.merge("requirement" => 0), behavior.merge("requirement" => 2),
      behavior.merge("observed" => "false"), behavior.merge("expected" => " ") ].each do |bad_behavior|
      expect { parse(keep.merge("behavior" => bad_behavior)) }.to raise_error(JudgeVerdict::Invalid)
    end
  end

  it "allows bounded scenario and question edits while refusing changes to requirements, code, or keys" do
    edit = keep.merge("status" => "edit", "case" => "flawed", "behavior" => behavior.merge("observed" => "false"), "issues" => [
      { "type" => "leakage", "evidence" => "The question hinted at a line." }
    ], "fields" => { "scenario" => "Describe how booking availability is reported." })

    expect(parse(edit)).to have_attributes(status: :edit, review_case: "flawed", fields: edit.fetch("fields"))
    [ "requirements", "file_1_code", "answer_key" ].each do |field|
      expect { parse(edit.merge("fields" => { field => "replacement" })) }.to raise_error(JudgeVerdict::Invalid)
    end
    expect { parse(edit.merge("fields" => { "question" => "x" * 301 })) }.to raise_error(JudgeVerdict::Invalid)
    expect { parse(edit.merge("fields" => { "scenario" => "Two\nlines" })) }.to raise_error(JudgeVerdict::Invalid)
  end
end
