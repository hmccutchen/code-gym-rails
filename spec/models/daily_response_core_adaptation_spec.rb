require "rails_helper"

RSpec.describe DailyResponse, "core adaptation" do
  def response(bug_answer: "answer", bug_grade: nil)
    exercise = DailyExercise.new(date: Date.new(2026, 1, 5), problem_set: {
      "code_review" => { "purpose" => "Find the trap", "snippet" => "x" },
      "pattern" => { "question" => "q" }, "design_comparison" => { "question" => "q" }
    })
    described_class.new(daily_exercise: exercise, submitted_at: Time.current,
      answers: { "code_review" => bug_answer, "pattern" => "answer", "design_comparison" => "" },
      ai_review: { "pattern" => { "rating" => "solid" }, "code_review" => { "rating" => bug_grade } })
  end

  [ [ "answer", "strong" ], [ "answer", nil ], [ "", nil ] ].each do |answer, grade|
    it "keeps core completion independent of bug #{[ answer, grade ].inspect}" do
      row = response(bug_answer: answer, bug_grade: grade)
      expect(row.adaptation_section_keys).to eq(%w[design_comparison pattern])
      expect(row.assessed_adaptation_sections).to eq([ "pattern" ])
      expect(row.completion_evidence?(sections: row.adaptation_section_keys)).to be(true)
      expect(row.completion_evidence?).to eq(answer.empty? || grade.present?)
    end
  end

  it "does not manufacture a skip event from only an assessed bug" do
    row = response(bug_grade: "strong")
    row.answers["pattern"] = ""
    expect(row.completion_evidence?(sections: row.adaptation_section_keys)).to be(false)
  end

  [ nil, [], "broken" ].each do |container|
    it "treats unreadable containers as absent: #{container.inspect}" do
      row = response
      row.daily_exercise.plan_notes = container
      expect(row.adaptation_section_keys).to eq([])
      expect(row.completion_evidence?(sections: [ "pattern" ])).to be(false)
    end
  end
end
