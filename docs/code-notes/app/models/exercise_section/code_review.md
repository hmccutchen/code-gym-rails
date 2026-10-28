# app/models/exercise_section/code_review.rb

## `MAX_SNIPPET_LINES`

The prompt asks for a snippet of about 10 to 15 lines, but until issue #599 nothing checked the reply, and a long snippet costs the most on a phone, where every extra line is more scrolling before the question.

The cap is `RealSource::MAX_LINES` (40) rather than a tighter number. A grounded day asks for a modified copy of a curated excerpt that keeps its shape, and an excerpt can be up to 40 lines, so a lower cap would refuse legitimate grounded sections. A spec runs every curated excerpt through the formatter and the check to hold that. A tighter cap for the toy modes would need a measurement of what providers actually return first.

Lines are counted after `ProblemSetIngest#format_code!`, so the cap measures the code as shown, and blank lines don't count, the same rule design comparison's `MAX_PIECE_LINES` uses (`ExerciseSection.shown_lines`).

A snippet over the cap is refused, never cut, since cutting code could cut out the planted flaw. `code_review` is a daily kind, so on a judged day a refusal gets up to two retries with its concept fixed before the section is dropped; a weekend set drops it straight away. The refusal message carries the line count and none of the code. A missing or blank snippet is refused the same way.
