# `ReviewPrompt`

The two-stage review's text, moved out of `AiService` (#431). `AiService#build_review_day_context` and `#build_review_section_prompt` still gather each section's values from the exercise and the response. `ReviewGrading` takes the day context as a callable, and `#grade_review` makes each call and stamps `ReviewedSectionResults::RUBRIC_VERSION`. The stamp lives with the evidence rules rather than here, since the competency gate and level suggestions read it through `ReviewedSectionResults` and raising it is a decision about evidence, not about wording.

## `.for_section`

The one place that chooses a section's review prompt: the graded prompt for an answered section, the walkthrough for an unanswered one. It takes `answered:` as a value rather than deciding from the answer text, since `DailyResponse#answered?` is the one authority on that and a prompt class reads no response (#583). An unanswered section's answer text is ignored.

## `.section_prompt`

It takes the rung as a value. `AiService#review_rung` chooses it: the section's stamped `pitched_at`, or else the user's current rung, which reads `KindDifficulty` for the user and so cannot happen in a prompt class.

## `RATING_RUBRIC`

Stated once, in the day-level system prompt, so the section prompts never repeat it and the grader reads one definition of the four ratings.

## `.walkthrough_prompt`

It shares the entry rules and the JSON header with `.section_prompt` but leaves out the per-kind grading note on purpose: a grading note brings grading instructions into a prompt that must request no grade. In its place it reads the kind's `walkthrough_note`, empty except for Parsons, which supplies the correct block order. It never asks for "rating" or "essential_gaps".

Both prompts end with the same fields, and the `improved_code` field line reads the kind's `.improved_code_instruction(section:, answered:)`. That hook is the one place a kind says what its improved code should hold, so the walkthrough gets it too. Before #642 pattern, plan review and pseudocode to code said it in their grading notes, which the walkthrough leaves out, so an unanswered section's improved code came with no instruction.

## `approach:`

Every prompt takes `approach:`, false by default, and hands it to `.shared_review_fields`, the one place `next_step` is stated for every kind. When it is false, the `next_step` line is `NEXT_STEP`, today's text, so the prompt is byte for byte what it was before the switch existed. A spec compares that against the recorded snapshot files with a plain file read. That read doesn't rewrite the files, but other specs record the same files under `UPDATE_PROMPT_SNAPSHOTS=1`, so after a recording run the proof is that `git diff` shows no change to any existing `review__*` snapshot. When it is true, an answered section asks for `APPROACH_NEXT_STEP` and a walkthrough for `APPROACH_NEXT_STEP_WALKTHROUGH`, which leaves out the answer because nothing was written. The value comes from `ReviewApproachParagraph.enabled?`, which `AiService#build_review_section_prompt` reads, so this class never reads the environment (`docs/decisions/the-approach-paragraph.md`).

## `why:`

The graded prompt and `.for_section` take `why:`, false by default; the walkthrough doesn't take it, because a walkthrough's "missed" list is already "what a good answer covers" and has no gap to explain. When `why:` is true and the kind's `.miss_reason` is present, `.miss_reason_line` adds `MISS_REASON` with the kind's reason filled in at `%{reason}`, on the line right after the grading note. The shared line is the one statement of the rule, and each kind's hook says only what its reason is about, so adding a kind is adding a `.miss_reason`, the same way `.improved_code_instruction` works. No grading note's text changes.

The line asks for the reason inside the entry it explains. A reason written as its own entry would shift the positions `essential_gaps` points at, which `RubricCheck` and the short version's pitfalls read. It asks for an explanation, not a different rating, so `RUBRIC_VERSION` stays where it is, and the prose judge's prompt and route are untouched. The reason is the grader's own reasoning: the line asks it to hedge with "likely" or "could" and never to claim the code ran.

A kind opts in only when its grader can find the reason without a key it isn't shown. `challenge`, `architecture` and `pattern` have no key at all. `architecture` has no single correct option, so its reason forbids "it didn't pick option X", which would invent one. `pattern`'s forbids "it isn't the named pattern", which would assume a model answer. `ambiguity_hunt`'s grader holds the planted list, which has no reasons, so every reason is its own; the reason is given only for a planted ambiguity they missed, so it can't add an unplanted one to "missed". `pseudocode_to_code` has a hidden key, `answer_key.missable_requirements`, that holds exactly this reason, and no grader reads it. Its reason points at the problem statement and the plan only, and ties the reason to the plan, so the grading note's rule that the translated code's syntax is never a fault still holds. A spec renders each opted-in kind with a planted key in its section and checks the key text appears no more often with the switch on, and never at all.

With the switch off, every prompt is byte for byte today's. `challenge`, `architecture` and `ambiguity_hunt` had no review snapshot, so `review__challenge__prompt`, `review__architecture__prompt` and `review__ambiguity_hunt__prompt` were recorded from the code before each kind's `.miss_reason` existed, and a spec compares them, pattern's two existing snapshots and `review__pseudocode_to_code__improved_code__prompt` with a plain file read. The switch-on prompts are recorded as `review__<kind>__miss_reason__prompt`. As with `approach:`, after a recording run the proof is that `git diff` shows no change to any existing `review__*` snapshot. The value comes from `ReviewMissReason.enabled?`, which `AiService#build_review_section_prompt` reads.
