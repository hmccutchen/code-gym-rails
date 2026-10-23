require "rails_helper"

RSpec.describe ReviewPrompt do
  let(:long) { "The loop loads each order's user separately, so the page runs one query per order; preload users first." }
  let(:day_a) do
    [ { key: "code_review", rung: "senior",
        section: { "question" => "What is wrong here?", "snippet" => "Order.all.each { |o| o.user.name }", "concept" => "n_plus_one", "pitched_at" => "senior" },
        answer: long, rating: "right_level" },
      { key: "design_comparison", rung: "junior",
        section: { "title" => "Rates", "scenario" => "A rates file read nightly.", "question" => "Which would you ship?",
                   "piece_a" => "a", "piece_b" => "b", "concept" => "information_hiding",
                   "answer_key" => { "better" => "b", "deciding_fact" => "The rates file format changes every quarter.",
                                     "principle" => "information_hiding", "why_other_fails" => "A spreads the format across every caller." } },
        answer: ExerciseSection::DesignComparison.encode_answer("b", "The rates file format changes, and B hides it behind one reader."),
        rating: nil },
      { key: "pattern", rung: "junior",
        section: { "title" => "Memoize", "question" => "When would you cache this?", "concept" => "memoization" },
        answer: long, rating: "too_easy" },
      { key: "parsons_problem", rung: "junior",
        section: { "title" => "Order", "question" => "Put these in order.", "blocks" => %w[a b c], "concept" => "guard_clauses", "pitched_at" => "junior" },
        answer: "order:0,2,1", rating: "too_hard" } ]
  end

  def day_sections(entries) = entries.map { |entry| entry.slice(:key, :section, :answer, :rating).merge(section: entry[:section].merge("rounds" => {})) }

  it "renders a four-section day's system prompt exactly as recorded" do
    expect_prompt_snapshot("review__day_a__system", described_class.day_system(coach: "Rails", sections: day_sections(day_a)))
  end

  it "renders each section's prompt exactly as recorded, at the rung it is handed" do
    day_a.each do |entry|
      prompt = described_class.section_prompt(key: entry[:key], section: entry[:section], answer: entry[:answer], rung: entry[:rung])

      expect_prompt_snapshot("review__day_a__#{entry[:key]}__prompt", prompt)
    end
  end

  it "renders a one-section day, which names no other section, exactly as recorded" do
    section = { "question" => "What breaks?", "snippet" => "items.map(i => fetch(i))", "concept" => "n_plus_one", "pitched_at" => "mid_level" }

    expect_prompt_snapshot("review__day_b__system",
                           described_class.day_system(coach: "JavaScript/React",
                                                      sections: [ { key: "code_review", section: section.merge("rounds" => {}), answer: nil, rating: nil } ]))
    expect_prompt_snapshot("review__day_b__code_review__prompt",
                           described_class.section_prompt(key: "code_review", section: section, answer: nil, rung: "mid_level"))
  end

  it "takes the rung as a value, so it never reads a user's difficulty settings" do
    expect(described_class.method(:section_prompt).parameters)
      .to eq([ [ :keyreq, :key ], [ :keyreq, :section ], [ :keyreq, :answer ], [ :keyreq, :rung ] ])
  end
end
