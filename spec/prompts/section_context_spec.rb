require "rails_helper"

RSpec.describe SectionContext do
  let(:full) do
    { "title" => "T", "scenario" => "S", "why" => "W", "question" => "Q", "options" => %w[a b], "snippet" => "code",
      "current_schema" => "schema", "starter_code" => "start", "plan_excerpt" => "plan", "problem_statement" => "P",
      "request" => "R", "piece_a" => "A", "piece_b" => "B" }
  end

  it "describes every field it knows, exactly as recorded" do
    expect_prompt_snapshot("section_context__full", described_class.render(full))
  end

  it "never shows an answer-key field" do
    keys = ExerciseSection.all_answer_key_fields.index_with { "ANSWER-KEY-SENTINEL" }

    expect(described_class.render(full.merge(keys))).to eq(described_class.render(full))
  end

  it "lists Parsons blocks in the learner's scrambled order, or unordered when no scramble was persisted" do
    blocks = %w[x y z]

    expect_prompt_snapshot("section_context__parsons_scrambled", described_class.render("blocks" => blocks, "display_order" => [ 2, 0, 1 ]))
    expect_prompt_snapshot("section_context__parsons_solved_order", described_class.render("blocks" => blocks, "display_order" => [ 0, 1, 2 ]))
  end

  it "lists unscrambled blocks the provider returned as mixed types without raising" do
    expect(described_class.render("blocks" => [ 2, "a", 1 ])).to eq("Blocks (order withheld):\n- 1\n- 2\n- a")
  end

  describe "a multi-file code review" do
    let(:files) do
      { "question" => "Q", "file_1_path" => "app/models/order.rb", "file_1_code" => "a = 1\nb = 2", "file_1_changed_lines" => [ 2 ],
        "file_2_path" => "app/models/item.rb", "file_2_code" => "c = 3", "file_2_changed_lines" => [] }
    end

    it "lists each file's path, changed lines and code" do
      expect_prompt_snapshot("section_context__code_review_files", described_class.render(files))
    end

    it "never shows the answer key" do
      keyed = files.merge("answer_key" => { "issue" => "ANSWER-KEY-SENTINEL" })

      expect(described_class.render(keyed)).not_to include("ANSWER-KEY-SENTINEL")
      expect(described_class.render(keyed)).to eq(described_class.render(files))
    end
  end

  it "describes a missing or empty section as nothing" do
    expect(described_class.render(nil)).to eq("")
    expect(described_class.render({})).to eq("")
  end
end
