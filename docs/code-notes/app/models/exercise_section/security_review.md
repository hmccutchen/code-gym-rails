# app/models/exercise_section/security_review.rb

## `MAX_SNIPPET_LINES`

Until issue #604 nothing checked this kind's snippet, though the prompt asks for about 10 to 15 lines and holds it to code_review's bar. The cap reads `CodeReview::MAX_SNIPPET_LINES` (40) rather than a tighter number of its own. This kind has no real-source pool, so it could take a lower cap, but no measurement of what providers return exists, and a cap set below that would refuse sections that are fine today. The owner chose to share code_review's cap, so the two discovery kinds hold one bar and the cap only stops a runaway reply.

`.reject_unusable!` counts lines the way code_review does, after formatting and without blank lines (`ExerciseSection.shown_lines`). A snippet over the cap is refused, never cut, since cutting could remove the planted vulnerability, and the message carries the line count and none of the code. A missing, blank or non-string snippet is refused the same way. On a judged day a refusal spends one of the retries `DailyPlan::Result#judge_retries` grants, with the concept fixed, before the section is dropped; a weekend set drops it straight away.

## `.broader_vocabulary_owner` and `.snippet_bar`

Both compare this section with others in the same request, so they name `code_review` or `pattern` only when `alongside:` holds them. A pair without `code_review`, or a retry of this kind alone, gets a line that stands on its own.
