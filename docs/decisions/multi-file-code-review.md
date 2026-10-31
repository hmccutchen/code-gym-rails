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

## Launch, revised (owner's decision, 2026-10-31)

The owner decided to put multi-file `code_review` live before keyed grading
(stored answer keys PR 2), with guards, instead of waiting for it. That
replaces the earlier "launch B waits for PR 2" order.

- **Launch A (built, #622):** rendering, caps, refusal codes and generation,
  with `CODE_REVIEW_FILE_WEIGHTS = { single: 1.0, multi: 0.0 }`.
- **Live with guards (next):** one PR that turns the mode on at
  `{ single: 0.75, multi: 0.25 }`, with:
  - **the key stored from the first multi-file day,** unread by the grader
    until PR 2, as PR 1 did for single-file keys (below)
  - **the judge paragraph** for sections with files: solve the section
    first, reject it when one file alone shows the problem or it is an
    exploit, and never change a path, a file's code or the changed lines
  - **a multi-file grading note that works without a key** (below)
  - **the read-only split script** (below)
  - **multi-file days kept out of PR 2's samples** (below)
- **With PR 2:** the grader reads multi-file keys too, the refusal rule for a
  failed multi-file key joins, a multi-file calibration fixture is added, and
  the early grades are compared with keyed ones (below).

At `mid_level` and above, 0.25 makes about 19% of Ruby `code_review` days
multi-file (`RealSource` keeps about 23% single, and a quarter of the other
77% roll multi) and about 25% of JavaScript days. A `junior` rung's range is
one file, so a junior day stays single-file whatever the roll. Setting the
weight back to `multi: 0.0` turns the mode off for new days.

### The stored multi-file key

- **Shape:** the single-file three (`issue`, `why_it_matters`, `fix`), plus
  `files` (2 or more of the section's paths) and `evidence` (2 to 4 entries,
  each a `file` from `files` and a `quote` copied from that file, covering
  at least 2 files). Every text is under `PlantedKey::MAX_LENGTH`.
- **A key that fails is dropped and the section is kept,** not refused,
  until PR 2. Ingest notes the reason, and `[planted_key]` logs it with no
  key text and a new `code_review_files=single|multi` field:
  - `missing`: no key, or a text field unusable
  - `too_long`: a field or evidence quote past `PlantedKey::MAX_LENGTH`
  - `files_unmatched`: `files` names fewer than 2 of the section's paths
  - `evidence_unlocated`: fewer than 2 evidence quotes found in their own
    file with `KeyQuote.find`, or the ones found cover only one file. A
    quote needs 12 non-whitespace characters, since it is searched in a
    whole file.
- **Counted** by the split script, by reason, so the owner sees how often a
  multi-file key fails before PR 2 decides whether a failure refuses the
  section.
- **The refusal rule joins with PR 2:** from then on a multi-file section
  whose key fails is refused (`answer_key_unusable`), since without a key the
  grader has to guess which interaction was planted.

### The grading note without a key

Until PR 2, the multi-file note grades on the code alone: full credit goes to
an answer that names the interaction across files that breaks, both sides of
it, and a fix that touches the right file or files. A finding confined to one
file earns credit only as far as it goes. The changed lines tell the grader
where the change is, never where the flaw is. The `improved_code` line
(#638) is unchanged. PR 2 adds the keyed wording beside it.

### The split script

`script/split_code_review_results.rb` is read-only and runs only with the
owner's approval of each query. It prints counts by shape (single or multi)
and rung: reviewed results and their ratings, and multi-file key notes by
reason. Saved output stays outside the repository and is deleted after use.

### Kept out of PR 2's samples

- **The quote check** counts only `code_review_files=single` lines, so a
  multi-file key, which quotes whole files, doesn't change the single-file
  threshold.
- **PR 2's measuring step** exports and regrades single-file sections only
  (`--keyed-only` gains a single-file filter). Multi-file sections get their
  own comparison, below.

### Regrading the early multi-file grades once PR 2 is on

The early grades rest on the note without a key, and they already count as
`code_review` evidence. Once PR 2 grades multi-file sections with their
keys, a read-only comparison checks them:

1. **Export,** with the owner's approval: reviewed multi-file sections whose
   key was stored, each with its stored review rating, its answer and its
   key, read-only, saved outside the repository. Sections whose key failed
   can't be compared, and the export reports how many.
2. **Regrade on the PR 2 branch,** on the owner's machine with the owner's
   key and the call count and cost approved first: each section 5 times
   with its key and 5 times without (today's note), so the run-to-run spread
   of the unkeyed grader is known.
3. **Compare, in counts:** how many sections' typical keyed rating differs
   from the stored rating, and in which direction, beyond the unkeyed
   spread. The stored rating is one draw from an older prompt, so the
   unkeyed regrade is the fair baseline beside it. At least 3 sections
   differing in the same direction is systematic.
4. **Nothing is rewritten.** A reviewed response is frozen evidence, so a
   systematic difference goes to the owner, who decides whether the early
   multi-file results stay in the evidence. Taking them out would need its
   own change.
5. **Delete the export.** Only the counts are recorded.

## Rating evidence, from the multi-file launch on

Multi-file sections count as `code_review` evidence at their rung, like any
other, for the competency gate and level suggestions. Ratings at
`mid_level` and above are expected to dip, because the rung now asks for more.
That is the rung working, not a change to what a rating means, so
`RUBRIC_VERSION` stays at 1 and no evidence is reset.

Until PR 2 those ratings come from the note without a key, so they rest on
the grader's own reading of the files; the comparison above checks them once
keys are read.

After the launch the owner may see a suggestion to step `code_review` back a
level, or a day that grows more slowly. That is the expected effect of the
harder rung. Setting the weight back to `multi: 0.0` reverses it for new days.
Results already reviewed stay in the evidence and drop out of the suggestion
window as new ones arrive.

Results don't record the shape; a section's file fields do. If multi-file
sections at a rung rate well below single-file ones at the same rung, the
owner lowers the weight or narrows the rungs before anything else changes.
With one account that comparison is a direction, not a verdict.
