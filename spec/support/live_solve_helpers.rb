module LiveSolveHelpers
  def live_solve(**overrides)
    section = { "question" => "Which fits?", "piece_a" => "a = 1", "piece_b" => "b = 2", "concept" => "open_closed",
                "answer_key" => { "better" => "b", "deciding_fact" => "SECRET fact" } }
    JudgedGeneration::Solve.new(
      section: "design_comparison", attempt: 0, edit_check: false, rung: "senior", locked: false, concept: "open_closed",
      judged_section: section, judge_status: "keep", judge_pick: "b", key_better: "b", matched: true,
      unsolved_reason: nil, unsolved_detail: nil, edit_reverted: false, revert_reason: nil,
      judge_provider: "anthropic", judge_model: "claude-sonnet-5-5", shipped: true, never_shown_reason: nil, **overrides
    )
  end
end

RSpec.configure do |config|
  config.include LiveSolveHelpers, file_path: %r{spec/jobs/}
end
