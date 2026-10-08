require "rails_helper"

RSpec.describe ConceptLesson do
  let(:reply) do
    {
      "definition" => " An action is idempotent when twice equals once. ",
      "comparison" => "A thermostat setting.",
      "comparison_limit" => "A thermostat has one setting.",
      "misunderstanding" => "It does not mean the code runs once.",
      "situations" => [ "A double tap.", "A retried job." ],
      "habits" => [ { "habit" => "Store the result.", "catch" => "Late updates can overwrite." } ],
      "carry_question" => "What would happen twice?",
      "quick_test" => "Run it twice."
    }
  end

  it "keeps every usable section, stripped" do
    lesson = described_class.from_provider(reply)

    expect(lesson.keys).to match_array(described_class::SECTIONS)
    expect(lesson["definition"]).to eq("An action is idempotent when twice equals once.")
  end

  it "drops a section that is blank, not a string, or too long, and keeps the rest" do
    lesson = described_class.from_provider(reply.merge(
      "comparison" => "  ", "misunderstanding" => 42, "quick_test" => "x" * (described_class::MAX_TEXT_LENGTH + 1)
    ))

    expect(lesson.keys).not_to include("comparison", "misunderstanding", "quick_test")
    expect(lesson).to include("definition", "situations", "habits")
  end

  it "drops a habit without a catch and caps both lists" do
    habits = Array.new(described_class::MAX_HABITS + 1) { |i| { "habit" => "h#{i}", "catch" => "c#{i}" } }
    lesson = described_class.from_provider(reply.merge(
      "habits" => [ { "habit" => "no catch" }, "not a hash", *habits ],
      "situations" => Array.new(described_class::MAX_SITUATIONS + 2) { |i| "s#{i}" }
    ))

    expect(lesson["habits"].map { |habit| habit["habit"] }).to eq(%w[h0 h1 h2 h3])
    expect(lesson["situations"].size).to eq(described_class::MAX_SITUATIONS)
  end

  it "drops the comparison and its limit together when either is unusable" do
    without_limit = described_class.from_provider(reply.merge("comparison_limit" => " "))
    without_comparison = described_class.from_provider(reply.except("comparison"))

    [ without_limit, without_comparison ].each do |lesson|
      expect(lesson.keys).not_to include("comparison", "comparison_limit")
      expect(lesson).to include("definition", "habits")
    end
  end

  it "describes the prompt's shape for every section, lists included" do
    schema = described_class.schema

    expect(schema.keys).to eq(described_class::SECTIONS)
    expect(schema.values_at(*described_class::TEXT_SECTIONS).uniq).to eq([ "string" ])
    expect(schema["situations"]).to eq([ "string" ])
    expect(schema["habits"]).to eq([ { "habit" => "string", "catch" => "string" } ])
  end

  it "is nil for a reply with nothing usable or no lesson at all" do
    expect(described_class.from_provider({ "definition" => "", "habits" => [] })).to be_nil
    expect(described_class.from_provider(nil)).to be_nil
    expect(described_class.from_provider("a lesson")).to be_nil
  end
end
