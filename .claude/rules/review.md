---
paths:
  - "app/services/{response_review,review_grading}.rb"
  - "app/clients/{review_prose_judge,ai_service}.rb"
  - "app/prompts/{review_prose_judge_prompt,review_prompt,difficulty_prompt,prompt_standards}.rb"
  - "app/models/{review_prose_verdict,rubric_check,daily_response,review_follow_up}.rb"
  - "app/controllers/responses_controller.rb"
  - "app/views/shared/_ai_review.html.erb"
  - "app/views/responses/{_submission,_review_in_progress,_answered_sections}.html.erb"
  - "app/views/review_mailer/**"
  - "spec/fixtures/{review_calibration,review_judge}/**"
  - "spec/**/*{review,rubric,grading,difficulty_prompt}*"
  - "app/models/exercise_section/**"
  - "app/models/{concept_mastery,rung_ledger}.rb"
---

# Review and grading

Each entry states what a change must not break. An entry that names a
`docs/decisions/` doc has its full reasoning, measurements and history there;
read it before changing that area.

- **Grading rubric** (`docs/decisions/grading-rubric.md`):
  `ReviewPrompt::RATING_RUBRIC` is the one definition of the four review ratings,
  graded against the section's `pitched_at` rung; `eased` is never passed to
  the grader. Per-kind grading notes name the main point and never restate the
  levels. Parsons' rating comes from its `fixed_rating` hook. `RubricCheck`
  only logs agreement and never rewrites a rating. The competency gate and
  `LevelSuggestion` read only `RUBRIC_VERSION`-stamped reviews;
  `ConceptMastery` and `RungLedger` read all history on purpose.
- **Review prose judge** (`docs/decisions/review-prose-judge.md`): An optional
  second pass that may reword a graded review's prose fields for plain
  language or length (`AiService#judge_review_prose`); it is never shown the
  answer, problem or grading note. `ReviewProseVerdict.parse` is the boundary:
  a list field must cite every original entry once, in order. `graded_prose`
  is server-owned. Any failure returns the grade unchanged, and it runs on
  Claude only. The call is `single_attempt: true`, and
  `DailyResponse::REVIEW_CLAIM_STALE_AFTER` (12 minutes) covers it, so the
  claim outlasts the grading chain. The switch (`REVIEW_PROSE_JUDGE`) is on;
  any change to its prompt or route must re-pass the doc's activation gate.
- **Post-hoc difficulty rating**
  (`docs/decisions/post-hoc-difficulty-rating.md`): A reviewed section shows
  how hard the problem was (`DailyResponse::DIFFICULTY_LEVELS`), kept disjoint
  from the grade vocabulary. `AiService#assess_difficulty` takes no response,
  answers, ratings or history, so it can never read out `ConceptMastery` tier.
  Any failure is swallowed so it never costs the review, and the result is
  display-only.
