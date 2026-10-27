---
paths:
  - "app/services/{response_review,review_grading}.rb"
  - "app/clients/{review_prose_judge,ai_service}.rb"
  - "app/prompts/{review_prose_judge_prompt,review_prompt,difficulty_prompt,prompt_standards}.rb"
  - "app/models/{review_prose_verdict,rubric_check,daily_response,review_follow_up,review_short_version}.rb"
  - "app/controllers/responses_controller.rb"
  - "app/views/shared/{_ai_review,_review_short_version}.html.erb"
  - "app/views/responses/{_submission,_review_in_progress,_answered_sections}.html.erb"
  - "app/views/review_mailer/**"
  - "app/helpers/review_helper.rb"
  - "app/mailers/review_mailer.rb"
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
  never rewrites a rating: it logs agreement, and its gap list also decides
  whether the short version shows pitfalls. The competency gate and
  `LevelSuggestion` read only `RUBRIC_VERSION`-stamped reviews;
  `ConceptMastery` and `RungLedger` read all history on purpose.
- **Unanswered sections are reviewed, not graded** (`docs/decisions/grading-rubric.md`):
  `ReviewPrompt.for_section` gives an unanswered section the walkthrough
  prompt, choosing on `DailyResponse#answered?` as a value. It stores no
  rating and no rubric stamp, `ai_rating_for` is nil for it, and
  `ReviewHelper#review_field_label` heads its "missed" list "What a good
  answer covers". `ReviewHelper#review_badge` shows "Skipped" in place of the
  grade badge. A short answer is an answer and is graded. `RUBRIC_VERSION` is
  unchanged.
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
- **Glossary terms in a review**: the review partial renders its prose fields,
  the difficulty reason and saved alternate explanations through
  `glossary_wrap`, and `ResponsesController#explain_differently` returns a new
  explanation as escaped, glossary-wrapped `alternate_html` beside the plain
  `alternate` it saves. The improved code and follow-up turns stay plain.
- **Post-hoc difficulty rating**
  (`docs/decisions/post-hoc-difficulty-rating.md`): A reviewed section shows
  how hard the problem was (`DailyResponse::DIFFICULTY_LEVELS`), kept disjoint
  from the grade vocabulary. `AiService#assess_difficulty` takes no response,
  answers, ratings or history, so it can never read out `ConceptMastery` tier.
  Any failure is swallowed so it never costs the review, and the result is
  display-only.
- **The concept's short version in the review**
  (`docs/decisions/first-exposure-teaching-in-the-review.md`):
  `ReviewShortVersion#offered?` is the one rule: a tagged, non-`"other"`
  concept on its first exposure (its `#key` counted once in `ConceptExposureIndex`) or
  with a `beginner` or `developing` grade, on the first qualifying section
  that carries the concept. It reads the exposure count and the section's
  own rating and review, never `ConceptMastery` (a convention spec scans
  for it). Pitfalls show when any section sharing the concept has an
  essential gap (`#pitfalls?`). The partial renders only what
  `ReviewHelper#review_short_version` returns: closed, after the review
  fields, only when the concept has a reference row; the review email
  leaves it out. Every reader of `graded_prose`
  goes through `ReviewProseVerdict.as_graded`.
