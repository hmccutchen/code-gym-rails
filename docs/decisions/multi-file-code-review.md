# Multi-file code review

`code_review` can show 2–3 files from one change, instead of one snippet, at
higher rungs. The flaw is one planted interaction: what a change in one file
breaks in another. This replaces the separate `change_review` kind that
`docs/change-review-spec-2026-10-27.md` proposed. That kind was never built.

## What the owner decided (2026-10-29)

- **A shape of `code_review`, not a new kind.** Rotation, the swap sheet and
  Setup's Exercise mix are untouched. Each mode (`application_code`,
  `test_file`, `schema_review`) has a multi-file shape, and keeps its own
  concept vocabulary and artifact. `RealSource` excerpts stay single-file.
- **The rung sets the file count** (`CodeReview.file_range`): `junior` 1,
  `mid_level` 2, `senior` and `principal_engineer` 2–3. Each day,
  `DailyPlan` rolls whether multi-file is allowed
  (`CODE_REVIEW_FILE_WEIGHTS`), and a `RealSource` day is always single-file.
  `DailyPlan` still reads no `KindDifficulty`. The rung turns the roll into a
  count where the draft is built.
- **Enforced at the boundary.** `ExerciseDraft` hands ingest the same range the
  prompt asked for, and `CodeReview.reject_unusable!` refuses a section
  outside it, with its own refusal codes and retry lines.
- **Caps:** 15 shown lines a file, and 40 in total, the same
  `MAX_SNIPPET_LINES` a single snippet has. Both are counted with
  `ExerciseSection.shown_lines` after formatting. A section past a cap is
  refused, never cut, since cutting could remove the flaw.
- **Changed lines** are quoted by the provider and resolved to line numbers
  after formatting through `KeyQuote`, since formatting can move lines. A
  quote that matches several lines, or none, is dropped rather than guessed.
  The numbers go in `file_N_changed_lines` and the quotes stay in
  `file_N_changed`, so the check gives the same result if it runs again
  (#623). The judge sees only the numbers, which are what the page marks
  (#625). Every prompt, the judge's included, shows a file's code with its
  lines numbered, so a model finds a changed line by its number rather than
  by counting (#630). The page numbers each file's lines in a gutter the
  same way, so a review or the duck that cites a line number points at a
  line the engineer can see, and the grader and duck prompts say the
  `N | ` prefix is not code, so it never reaches `improved_code` (#634).
  The improved code stays one string, and for a multi-file section the
  grader starts each changed file's part with a `File: <path>` line, so the
  engineer can tell which file each part replaces (#638). A per-file
  `{ path, code }` shape was the alternative; it would need a new review
  shape, its parsing and every reader of `improved_code` changed, for a
  label the line already gives.
- **One matcher.** `KeyQuote` holds the quote-matching rule for stored keys
  and changed lines alike. It keeps the stored keys rule (all whitespace
  ignored) and adds the comma and JavaScript rules that undo the formatters'
  rewrites. Those rules mostly let more quotes match, but not always: a
  JavaScript quote that stops just before an arrow, such as
  `done = (order)` against `const done = (order) => order.paid;`, now
  misses (`docs/code-notes/app/models/key_quote.md`).
- **No diagram** on a multi-file section, and the judge solve stays off.

## Launch in two steps

- **Launch A (built):** rendering, caps, refusal codes and generation, with
  `CODE_REVIEW_FILE_WEIGHTS = { single: 1.0, multi: 0.0 }`. No real day asks
  for files.
- **Launch B (waits for keyed grading of `code_review`, stored answer keys
  PR 2):**
  - the key gains `files` and `evidence`, each `evidence` entry under
    `PlantedKey::MAX_LENGTH` like any key field, so a too-long entry drops
    the whole key with a `too_long` note, and a multi-file key that fails
    refuses its section
  - the grading note gets its multi-file branch for what to grade (its
    `improved_code` line is already built, #638)
  - the judge gets a paragraph for sections with files: solve the section
    first, reject it when one file alone shows the problem or it is an
    exploit, and never change a path, a file's code or the changed lines
  - a multi-file calibration fixture
  - a read-only script that splits `code_review` results by shape
  - then the weight goes to `{ single: 0.5, multi: 0.5 }`

  At `mid_level` and above, that makes about 38% of Ruby `code_review` days
  multi-file (`RealSource` keeps about 23% single) and 50% of JavaScript days.
  Setting the weight back to `multi: 0.0` turns the mode off for new days.

## Rating evidence, from launch B on

Multi-file sections count as `code_review` evidence at their rung, like any
other, for the competency gate and level suggestions. Ratings at
`mid_level` and above are expected to dip, because the rung now asks for more.
That is the rung working, not a change to what a rating means, so
`RUBRIC_VERSION` stays at 1 and no evidence is reset.

After launch B the owner may see a suggestion to step `code_review` back a
level, or a day that grows more slowly. That is the expected effect of the
harder rung. Setting the weight back to `multi: 0.0` reverses it for new days.
Results already reviewed stay in the evidence and drop out of the suggestion
window as new ones arrive.

Results don't record the shape; a section's file fields do. If multi-file
sections at a rung rate well below single-file ones at the same rung, the
owner lowers the weight or narrows the rungs before anything else changes.
With one account that comparison is a direction, not a verdict.
