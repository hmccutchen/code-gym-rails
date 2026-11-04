# Extended into CodeReview, so each hook answers as the kind's own class method (code_review/bug_hunt.md).
module ExerciseSection::CodeReview::BugHunt::KindHooks
  BugHunt = ExerciseSection::CodeReview::BugHunt

  def bug_hunt?(section) = BugHunt.section?(section)

  def multi_file_mode?(mode) = !BugHunt.mode?(mode)

  def planning_host?(mode:) = mastery_evidence_mode?(mode)

  def mastery_evidence?(section) = mastery_evidence_mode?(bug_hunt?(section) ? BugHunt::MODE : nil)

  def mastery_evidence_mode?(mode) = !BugHunt.mode?(mode)

  def judge_task_for(section) = bug_hunt?(section) ? BugHunt::Prompt::JUDGE_TASK : judge_task

  def judge_guidance_for(section) = bug_hunt?(section) ? BugHunt::Prompt::JUDGE_GUIDANCE : judge_guidance

  def snippet_context(section) = BugHunt.snippet_context(section)

  def concept_shown_before_submission?(section) = !bug_hunt?(section)

  def concept_hidden_in_plan?(mode:) = BugHunt.mode?(mode)

  def ships_unjudged?(section) = !bug_hunt?(section)
end
