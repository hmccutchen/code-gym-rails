require "rails_helper"
require Rails.root.join("script/key_triage")

RSpec.describe KeyTriage do
  let(:kind)    { ExerciseSection::CodeReview }
  let(:section) { FakeService::EXERCISE_PROBLEM_SET.fetch("code_review").deep_dup }

  def compared(issue) = described_class.compare(kind, section, issue, language: "ruby_rails")

  def outcome(issue) = compared(issue)["triage"]

  describe ".compare" do
    it "agrees when the solver quotes lines that overlap the key's" do
      expect(outcome("`total = customer.orders.sum(&:total_cents)` queries once per customer")).to eq("agree")
    end

    it "disagrees when the solver quotes other lines" do
      expect(outcome("`customers.each { |c| puts loyalty_tier(c) }` prints instead of returning")).to eq("disagree")
    end

    it "is unlocated when the solver quotes nothing the code holds, or only a quote too short to place" do
      expect(outcome("the loop is slow")).to eq("unlocated")
      expect(outcome("`Customer.find_each` is missing")).to eq("unlocated")
      expect(outcome("`c`")).to eq("unlocated")
    end

    it "is unlocated, not agreed, when a solver's short quote appears more than once in the code" do
      section["snippet"] = "def index\n  @orders = Order.all.each { |o| o.user.name }\nend\n\ndef update\n  order.update(params[:order])\nend"
      section["answer_key"]["issue"] = "`Order.all.each { |o| o.user.name }` loads each user"

      expect(outcome("Unpermitted params passed straight to `update`, on the `order` record")).to eq("unlocated")
    end

    it "records the lines each side's quotes land on, so the sheet shows which side is unlocated and how wide a match is" do
      expect(compared("`customers.each { |c| puts loyalty_tier(c) }` prints"))
        .to include("solver_lines" => { "snippet" => [ "10" ] }, "key_lines" => { "snippet" => [ "2" ] })
      expect(compared("the loop is slow")).to include("solver_lines" => {}, "key_lines" => { "snippet" => [ "2" ] })
    end

    it "is unlocated when the key has no quote the code holds" do
      section["answer_key"]["issue"] = "`Order.where(paid: true)` is wrong"

      expect(outcome("`total = customer.orders.sum(&:total_cents)`")).to eq("unlocated")
    end

    it "places quotes in the schema a migration review shows beside its snippet, never across the two" do
      section.merge!("snippet" => "add_column :orders, :total, :integer", "current_schema" => "create_table :orders do |t|\n  t.integer :total\nend",
                     "answer_key" => { "issue" => "`add_column :orders, :total, :integer` duplicates a column" })

      expect(outcome("`t.integer :total` already exists")).to eq("disagree")
      expect(outcome("`add_column :orders, :total, :integer` repeats `t.integer :total`")).to eq("agree")
    end
  end

  describe ".solve_prompt" do
    it "renders the solve request exactly as recorded" do
      request = described_class.solve_prompt(kind, section)

      expect_prompt_snapshot("triage_solve__code_review__system", request[:system])
      expect_prompt_snapshot("triage_solve__code_review__prompt", request[:prompt])
    end

    it "shows the section without its key, server stamps, hidden fields, concept or locked hint" do
      section.merge!("answer_key" => section["answer_key"].transform_values { "SENTINEL-KEY" }, "pitched_at" => "SENTINEL-STAMP",
                     "file_1_changed" => [ "SENTINEL-QUOTE" ])

      request = described_class.solve_prompt(kind, section)

      expect(request.values.to_json).not_to include("SENTINEL")
      expect(request[:prompt]).not_to include("n_plus_one")
      expect(request[:prompt]).not_to include(section["teaching_note"])
      expect(request[:prompt]).to include(section["snippet"].lines.first.strip)
    end
  end

  describe ".reply" do
    it "keeps a text issue and fix, and refuses anything else" do
      expect(described_class.reply("issue" => " a ", "fix" => "b", "extra" => 1)).to eq("issue" => "a", "fix" => "b")
      expect { described_class.reply("issue" => "a") }.to raise_error(ProviderError::InvalidResponseError)
      expect { described_class.reply([]) }.to raise_error(ProviderError::InvalidResponseError)
    end
  end

  describe ".sheet_sections and .summary" do
    def entry(mode, triage) = { "code_review_mode" => mode, "triage" => triage }

    let(:entries) do
      [ entry("application_code", "agree"), entry("application_code", "agree"), entry("application_code", "disagree"),
        entry("test_file", "unlocated"), entry("schema_review", "agree") ]
    end

    it "keeps every disagreement and unlocated section, and the first agreement of each mode that has one" do
      expect(described_class.sheet_sections(entries)).to eq([ entries[2], entries[3], entries[0], entries[4] ])
    end

    it "counts outcomes overall and by mode, and names a mode with no agreement" do
      expect(described_class.summary(entries)).to eq([
        "triage: agree 3 · disagree 1 · unlocated 1",
        "  application_code agree 2 · disagree 1 · unlocated 0",
        "  test_file agree 0 · disagree 0 · unlocated 1",
        "  schema_review agree 1 · disagree 0 · unlocated 0",
        "no agreement to read for: test_file"
      ])
    end
  end
end
