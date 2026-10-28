# Spec: `change_review`, a review of a small change across 2–3 files (2026-10-27)

Checked against origin/main at `056b9dc`. Not built yet. The build waits
until the stored answer keys build (`docs/stored-answer-keys-spec-2026-10-27.md`)
has merged, because this kind reuses its `answer_key` field and its quote
check (section 11).

## Decisions

Made by the owner on 2026-10-27:

- **A separate kind, not a `code_review` mode.** It gets rotation spacing,
  its own judge guidance and its own blind-solve setting, and it takes an
  existing section slot instead of making the code review longer.
- **Post-change files with the changed lines highlighted.** No `+`/`-` diff,
  since a diff loses formatting and highlighting.
- **Concepts:** `authorization`, `validations`, `callbacks_vs_service` and
  `ConceptVocabulary::DATA_MODELING_CONCEPTS`.
- **Every rung, offered to everyone (2026-10-28).** No gate: a rung or a lock
  never removes a kind from the plan, and a new kind has no rung history to
  gate on. `change_review` enters rotation like any third, and the rung shapes
  the problem instead: 2 files with a more visible interaction at the lower
  rungs, up to 3 with a subtler one higher up (section 5).
- **Toy files only.** No `RealSource`. Every file is in the day's language.
- **Caps:** 15 lines per file and 40 lines in total, enforced in
  `.reject_unusable!` after formatting.
- **Answer key:** `answer_key` and the quote check from the stored answer keys
  spec. A key that fails is rejected at `.reject_unusable!`.
- **JavaScript days (2026-10-28): the 5 data-modeling concepts only.** The
  guidance names a Knex-style JavaScript migration and never Prisma, so every
  file is JavaScript. The quote comparison treats `'` and `"` as equal,
  ignores a trailing `;` and collapses line breaks, since Prettier re-wraps
  long lines. A stop condition watches JavaScript quote misses. The
  JavaScript vocabulary is not widened, and the kind isn't limited to Ruby.

Since nothing gates the kind, `DailyPlan` keeps its rule that it never
reads `KindDifficulty` (`.claude/rules/planning.md`, "Difficulty targets and
locks"), unchanged.

Every decision the build needs is made.

## 1. A rotating third, offered to everyone

### Which slot it competes for

`change_review` joins `ExerciseSection.thirds`, appended after
`ParsonsProblem`: `[ Architecture, SecurityReview, Challenge, ParsonsProblem,
ChangeReview ]`. It is also appended to `ExerciseSection.all`, since registry
order is the order starved kinds drain in (`SectionRotation.most_stale`).

The third slot is the right one:

- It's on the main concept track. `change_review` tags concepts in the
  language bucket (`ConceptBucket.for` returns the language for any kind
  without a special bucket), the same track as `code_review`, `pattern` and
  the other thirds.
- The fourth slot is for language-independent kinds with their own
  vocabularies and buckets (`docs/decisions/the-fourth-slot.md`).
  `change_review` uses the language vocabulary, so it doesn't belong there.
- The third slot fills only on a day of 3 or more sections (`DaySize`), so a
  two-section day never gets it. Adding the kind doesn't make any day longer.
  On a day with a third section, it can replace another third.

### How often it comes up

Rotation handles it like any kind. `SectionRotation.pick_kind` weighs each
eligible third by its staleness times the user's multiplier, and forces any
kind unseen for more than `STARVATION_LIMIT` (10) days. With five thirds
instead of four, each of the old four comes up about a fifth less often, for
every user. A user who doesn't want `change_review` can exclude it or lower
its weight in Setup's Exercise mix, as for any third.

The stored answer keys spec's Measuring section expects about 3–5
`security_review` sections in two weeks. With five thirds that becomes
roughly 2–4. If both builds land in the same fortnight, Measuring should wait
longer for `security_review` rather than read a smaller sample.

### What doesn't change

`change_review` is an ordinary rotating third, so the readers that offer a
kind need no change: `SectionRotation`, `CoverageException.candidate_kinds`,
`KindPreferences` and Setup's Exercise mix, `SectionKindSettings`,
`DailyKindSwap` (a user may make it a daily kind like any other), `DayHosts`
and `ConceptHosts`. None of them reads a rung, and this kind doesn't add one.

### A future option: limiting availability by track

If availability ever needs limiting, it will be by track, not by difficulty.
That isn't built here. One thing to settle first: in this codebase a track
*is* the skill level, "stored nowhere else" (`.claude/rules/levels.md`,
"Tracks"). Generation, both judges, `ConceptMastery` and `KindDifficulty`
never read track or suggestion state, and `level_suggestion_isolation_spec`
pins that. A track-based limit would therefore need its own decision on what
a track is beyond the skill level, and on which reader may consult it.

## 2. The shape

### Fields

Flat fields, so `ProblemSetIngest#format_code!` formats the code with no
change to shared code. It formats each `.code_fields` value that is a
non-blank string, and skips the rest.

```
"change_review": {
  "title": "string — a short name for the change",
  "scenario": "string — the business framing and what the change is for",
  "question": "string — what to review, never where the flaw is",
  "teaching_note": "string — a hint toward the key insight, never the answer",
  "concept": "string — exactly one concept from the provided vocabulary",
  "file_1_path": "string — a realistic path, e.g. app/models/order.rb",
  "file_1_code": "string — the whole file region after the change, at most 15 lines",
  "file_1_changed": ["string — each line this change added or edited, copied exactly"],
  "file_2_path": "…", "file_2_code": "…", "file_2_changed": ["…"],
  "file_3_path": "… (optional)", "file_3_code": "… (optional)", "file_3_changed": ["… (optional)"],
  "answer_key": { … section 3 … }
}
```

- `.code_fields` returns `%w[file_1_code file_2_code file_3_code]`.
- `.prose_fields` returns `%w[title scenario question teaching_note]`.
- Paths and changed lines are not prose, so the judge can't rewrite them.
- `.diagrammable?` is false. 2–3 files already show the structure, and a
  diagram of how they connect would point at the flaw.

### Changed lines: quoted, then resolved to line numbers at ingest

The provider quotes each changed line's text, not its line number, for the
same reason the stored answer keys spec gives: `format_code!` re-indents
Ruby (whitespace-only RuboCop `Layout` cops), and those cops can add or
remove blank lines, so a number written before formatting can point at the
wrong line.

`.reject_unusable!` runs after `format_code!`. It resolves each quoted line
with the same matcher as the answer key's quotes (section 3) and replaces
`file_N_changed` with the sorted unique 1-based line numbers:

- On a Ruby day, each quoted line resolves to the first formatted line that
  matches it.
- On a JavaScript day, Prettier may have re-wrapped a changed line onto
  several lines, so every formatted line its match spans is marked. A quoted line that matches nothing is dropped and counted. The
section is refused when no file has a resolved changed line, since then
nothing marks the change. `file_N_changed` isn't added to
`ProblemSetIngest::SERVER_STAMPS`. That list is stripped after
`reject_unusable!` runs (`strip_server_stamps!`), so a stamp there would
erase the resolved numbers. `.reject_unusable!` replacing the provider's
value with a checked one is the same pattern as
`AmbiguityHunt.reject_unusable!` replacing `planted_ambiguities`.

### Rendering the changed lines through `CodeHighlight`

- `CodeHighlight.html(code, lexer:, changed: [])` passes `changed` to
  `LineFormatter.new(changed:)`. The formatter counts lines as it streams
  them, and adds the class `code-line-changed` to the `span.code-line` of
  each changed line. Line-wrapping and alignment don't change.
- **Cache key:** today it is `[ rouge_lexer.tag, Digest::SHA256.hexdigest(code) ]`.
  It becomes `[ rouge_lexer.tag, Digest::SHA256.hexdigest(code), changed.sort.join(",") ]`.
  Without that, the same code shown once with marks and once without would
  share a cache entry and show the wrong marks. Every existing caller passes
  no `changed`, so its key gains an empty string and its HTML is unchanged.
- `SyntaxHighlightingHelper#highlighted_code(code, language, changed: [])`
  passes it through.
- The style is a background and an inset left bar (`box-shadow`), never
  padding or a border, so a changed line is the same width as an unchanged
  one and `code-lines` measures the same wrap. Add a `--code-changed-bg`
  color for both themes beside `--code-bg`.
- Color alone doesn't reach a screen reader, so each file's summary says it
  in words: "app/models/order.rb — changed lines 3–5, 9" (section 8).

## 3. The answer key

`answer_key` is the field `design_comparison` and, after the stored answer
keys build, `code_review`, `security_review`, `plan_review` and
`pseudocode_to_code` use. `.answer_key_fields` returns `[ "answer_key" ]`, so
`ExerciseSection.all_answer_key_fields` doesn't change and every strip site
covers this kind with no change: the judge, the duck, the difficulty
assessment, `GenerationDiagnostics`, every page and `script/compare_models.rb`.

Its shape is `code_review`'s from that spec, plus `files` and `evidence`,
which the per-file quote check needs:

```
"answer_key": {
  "issue": "what is wrong, naming both sides of the interaction",
  "why_it_matters": "what goes wrong because of it in this code",
  "fix": "a fix that works as written, naming which file or files it changes",
  "files": ["the paths whose code the flaw depends on, at least 2"],
  "evidence": [ { "file": "one of those paths", "quote": "a line from that file, copied exactly" } ]
}
```

- The generation guidance carries the line the stored keys spec copies from
  `ambiguity_hunt`: the key is hidden grading data, never restated, hinted at
  or echoed in the question, the scenario or the teaching note.
- `evidence` has 2 to 4 entries. The quote check needs each quote tied to the
  file it is in, and free text in `issue` can't say which file a quote comes
  from.

### The checks, all in `.reject_unusable!`, after formatting

The stored keys spec keeps a section whose key fails, because its four kinds
can still be graded the way they are today. This kind can't: without the key
the grader has to guess which interaction was planted across 2–3 files,
which is the guess the key removes, and a wrong guess here grades against a
different pair of files. So a key that fails refuses the section.

A key is refused when any of these fails:

- `issue`, `why_it_matters` and `fix` are non-blank strings. Each is
  stripped and truncated to the stored keys spec's bound (about 500
  characters).
- `files` names 2 or more different paths, each equal to one of the
  section's `file_N_path` values.
- Each `evidence` entry's `file` is one of those paths, and its `quote` is
  found in that file's formatted code (the matching rules are below). This is
  the stored keys spec's quote check, run per named file.
- Each quote has at least 12 non-whitespace characters, so a quote such as
  `}` or `end` can't pass the check by appearing anywhere.
- The matched quotes cover at least 2 different files.

**How this fits the stored keys plan
(`docs/stored-answer-keys-plan-2026-10-27.md`).**
- `ChangeReview.planted_key?` is true, and `.unquoted_key_parts(section)`
  returns the `evidence` quotes not found in their named file.
- That plan's kinds only report a miss: `ProblemSetIngest` records the
  outcome `quote_missing` in a `KeyNote`, and `GenerationDiagnostics` logs it
  as `answer_key=quote_missing`.
- For this kind, `.reject_unusable!` calls the same hook and raises
  `ProviderError::InvalidResponseError` when it returns anything, or when the
  quotes cover fewer than 2 files. The refusal goes through `unusable_sections`
  and the `[unusable_section]` log, with no quoted text in the message,
  because a message can reach a log and a quote is answer key.
- A delivered `change_review` section therefore always gets the note `ok`.
- What a refusal costs is in section 10.

**Matching rules, one matcher for quotes and changed lines.**

- **Ruby:** a quote matches when, with whitespace collapsed, it is found
  within one formatted line. The RuboCop `Layout` cops ingest runs never
  re-wrap a line (`Layout/LineLength` is excluded), so a line written on one
  line stays on one line.
- **JavaScript:** Prettier rewrites more than whitespace, so a miss would
  otherwise refuse sections whose key was right. Before comparing, both the
  quote and the file's formatted code are normalized:
  - all whitespace collapsed, line breaks included, so a quote Prettier
    re-wrapped onto two or more lines still matches the text it spans
  - `'` and `"` treated as the same character
  - a `;` at the end of the quote ignored

  The comparison runs against the whole normalized file, not one line at a
  time, since a re-wrapped quote crosses lines.

The stored keys spec counts its quote threshold on Ruby only, because of
these same Prettier rewrites. Here a miss refuses the section, so the
JavaScript refusal rate gets its own stop condition (section 10).

## 4. Concepts, and staying out of `security_review`'s way

`.vocabulary_key` stays `:concepts`, the language vocabulary, so tagging and
history go to the language bucket. `.narrow_vocabulary(vocabulary, rung:)`
returns `vocabulary & HOSTED_CONCEPTS`, where:

```ruby
HOSTED_CONCEPTS = (%w[authorization validations callbacks_vs_service] +
                   ConceptVocabulary::DATA_MODELING_CONCEPTS).freeze
```

That gives 8 concepts on a Ruby day, and the 5 data-modeling concepts on a
JavaScript day, because `JS_CONCEPTS` has none of the other three. The kind is in no
`ConceptVocabulary::GROUPS` entry and adds no prompt line per group, so the
"one prompt line per vocabulary group" pattern is unaffected. `pattern` and
the other thirds keep their full vocabularies. On a `code_review`
`schema_review` day, `change_review` can host the same data-modeling concept
as `code_review` that day. `DayHosts` then offers a due check to either
host, which is how every shared concept already works.

### Concepts repeat on JavaScript days, and nothing trips

On a JavaScript day `change_review` draws from 5 concepts, so the same
concept comes back more often than in any other code kind. I checked
everything that reacts to a concept recurring. None of it blocks a repeat or
misbehaves:

- **Rotation and starvation count kinds, not concepts.** `SectionRotation`'s
  staleness, `STARVATION_LIMIT` and `CoverageException`'s gaps all read
  section keys from history, never concept tags. A repeated concept doesn't
  change how often `change_review` comes up.
- **No code stops a concept repeating.** The generation prompt asks the
  provider to "avoid the same pattern two days in a row" and says concepts
  rated "too easy" must not repeat within the same week. Both are advisory
  text, and nothing checks them. With 5 concepts and the kind coming up
  every few days at most, a week where every data-modeling concept was last
  rated too easy is possible but rare. The provider then picks a repeat, and
  nothing refuses the section.
- **Reinforcement, retention and drills are per concept and rating-driven.**
  `ConceptMastery`, `User#concepts_needing_reinforcement`, retention checks
  and drills move on ratings and schedules, and `DayHosts` offers a concept
  only where today can tag it. A small pool means a due data-modeling check
  is likelier to find a host. It never forces one.
- **Two effects follow from exposure counts, both intended:**
  - `ConceptExposureIndex` counts each delivered tag. Repeats reach a
    concept's second exposure sooner, so `improved_code` shows sooner
    (`DailyResponse`'s count of 2 or more).
  - The planned first-exposure short version (#596's plan) is offered less
    often on these concepts, because their first exposure passes sooner.
- **Tagging:** if the provider tags a concept outside the JavaScript
  vocabulary, `ProblemSetIngest#normalize_concepts!` records it as `"other"`,
  as for every kind.

The pool grows only if `JS_CONCEPTS` grows, which is a separate decision.

**No overlap with `security_review`, by vocabulary.** `security_review` draws
only from `RAILS_SECURITY_CONCEPTS` (`mass_assignment_protection`,
`sql_injection_prevention`), and `authorization` isn't in it. The two kinds
share no concept, so a concept's history never splits between them. Their
framing differs as well:

- A `security_review` asks for a vulnerability and its exploit: one snippet,
  one attack.
- An `authorization` `change_review` asks what a change broke between files.
  For example, a controller that stops calling a policy another file assumes
  it calls, or a new caller that skips a check every other caller makes. The
  question is "what does this change break", never "how would an attacker
  use this".

The generation guidance says so in one line: an `authorization` flaw here is
a broken contract between files, never an injection or mass-assignment flaw.
If `security_review` later gains `authorization`, that line becomes the place
to draw the boundary.

## 5. How the rung shapes the problem

Every rung gets the kind. The rung decides how many files the flaw spans and
how visible the interaction is. `.generation_guidance(rung:)` states one line
per rung, built on `KindDifficulty::LEVEL_DEFINITIONS`, since every kind's
guidance already receives `rung:`:

| Rung | Files | The interaction |
|---|---|---|
| `junior` | 2 | Visible from the changed lines. The change calls or contradicts a line in the other file directly, such as a caller that still passes the old argument right beside the changed signature. |
| `mid_level` | 2 | Not pointed out. Finding it means reading the second file closely, not spotting a label. |
| `senior` | 2–3 | Subtler. The broken assumption sits in a file the change didn't touch, alongside a realistic constraint. |
| `principal_engineer` | 3 | The subtlest. The assumption is implicit, such as a callback, a default or a database constraint, and the fix carries a cost on each side. |

- **Not enforced at the boundary.** The per-rung file count is prompt
  guidance. `.reject_unusable!` receives only the section, and
  `ProblemSetIngest` stamps `pitched_at` after the boundary checks, so the
  boundary enforces only the 2–3 range for every rung (section 7).
- **The judge checks the fit.** It sees the rung ("Pitched at:") and judges
  whether the section fits it (section 9).
- **Easing:** a reduced-tier concept can be eased (`eased: true`). That
  changes the concept's tier in the prompt, never the rung or the file range,
  so an eased section still spans at least 2 files.
- **Ladders:** the per-concept ladder rungs in `ConceptReference` already
  cover these 8 concepts, since `code_review` uses them. Prepare ladders
  (`POST /learn/prepare_ladders`) reaches this kind once it is pickable.

## 6. Toy files, in the day's language

No `RealSource` entry and no `source` stamp. `ProblemSetIngest#ground_code_review!`
reads `code_review` only and is unchanged. The scenario is the provider's,
under the day's scenario flavor, as for every other kind. Every file is in
the day's language: Ruby, or JavaScript with a Knex-style migration, never a
Prisma schema. So `highlighted_code` uses the day's lexer for each file.

## 7. Caps

Enforced in `.reject_unusable!`, after `format_code!`, so they count the
lines as shown:

- 2 or 3 files: `file_1` and `file_2` required, `file_3` optional and
  ignored unless its path and code are both present.
- Each file at most 15 lines (`MAX_FILE_LINES`), all files at most 40 in
  total (`MAX_TOTAL_LINES`). Blank lines count, since they take room on a
  phone.
- Paths are non-blank, at most 120 characters (`MAX_PATH_LENGTH`) and
  different from each other.

A section over a cap is refused, never truncated. Cutting code could cut the
flaw out of it.

## 8. The phone layout

`bodies/_change_review.html.erb` copies `_design_comparison.html.erb`:

```erb
<%# Locals: data, exercise, response, submitted. %>
<% ExerciseSection::ChangeReview.files(data).each do |file| %>
  <details class="comparison-piece" open>
    <summary><%= file.path %><%= changed_lines_label(file.changed) %></summary>
    <pre class="snippet"><%= highlighted_code(file.code, exercise.language, changed: file.changed) %></pre>
  </details>
<% end %>
```

- **`ChangeReview.files(section)`** returns the present files as small
  values (`path`, `code`, `changed`), in order. It is the one reader of the
  `file_N_*` fields, and the duck, the grader, the judge and the page all use
  it.
- **The summary** gets design comparison's 44px row. A long path wraps,
  because it's text, not code.
- **The answer** is the shared `responses/answers/textarea` partial.
- **`code-lines` inside `<details>`:** the controller sits on the layout
  element and looks for every `code.highlight` with alignment padding when it
  connects. It watches the `<pre>`, and its notes cover a block in a closed
  disclosure: the block measures zero, `fit` returns, and the observer fits
  it when it opens. These disclosures start open, as design comparison's do,
  so each file fits on load and again on each width change. A user folding a
  file and opening it again gets the same refit. A system spec pins this
  (section 10).
- **Page width:** `pre.snippet` uses `pre-wrap` with `overflow-wrap: anywhere`,
  so a long line wraps and a 320px phone never scrolls sideways. 40 lines is
  the most a section shows. The 15-line cap keeps any one file to about
  a screen and a half on a phone.

## 9. Grading and the judge

### The grading note

`.grading_note(section:, answer:)` follows the stored keys spec's rule for a
different finding, in this kind's terms:

> Main point: the one planted interaction — what the change in one file
> breaks in another. Essential pieces: naming both sides (which files, and
> how they now disagree), why it is a problem in this code, and a fix that
> works as written. A finding in one file alone meets the main point only if,
> left as written, it would do at least as much harm in this code as the
> answer key's why_it_matters describes. A real but lesser finding is
> credited in "correct", and the keyed interaction stays an essential gap in
> "missed".

With no key, a section is never stored (section 3), so the note has no
keyless wording.

`.review_context` lists each file under its path, then the answer key line
the stored keys spec defines ("Answer key (hidden from the engineer, known
here for grading): …"), then the answer and rating. A skipped section's
walkthrough gets the key through the day context, as in that spec, so "What
a good answer covers" names the planted interaction.

`.improved_code_label` is "Corrected change". The grader's `improved_code`
starts each file it changes with a comment line naming its path, so one block
can show a fix across two files. `ResponseReview`'s existing visibility rule
for improved code still decides when it shows.

### The judge

`.judge_task`: "Find the one planted problem that comes from how these files
interact, and say which files it involves and how to fix it."
`.discovery?` is true.

`.judge_guidance`:

> This section shows 2–3 files after one change, with the changed lines
> listed. Solve it before judging: find the planted problem and list which
> files you had to read to see it. Reject as scope_mismatch if one file alone
> shows the problem, since that makes this a code review. Reject as
> scope_mismatch if the section doesn't fit its rung: at junior the
> interaction must be visible from the changed lines, and above mid_level it
> must not be. Reject as
> scope_mismatch if the problem is an exploit rather than a broken contract
> between files. Reject as underdetermined if more than one interaction
> problem is equally plausible. When you edit, you may reword the title,
> scenario, question and teaching note; never change a path, a file's code
> or the changed lines.

The judge never sees the key (`SectionJudgePrompt` strips `answer_key`). So
it checks "takes more than one file" on its own, from the code. The
`scope_mismatch` and `underdetermined` principles already exist in
`JudgeVerdict::PRINCIPLES`, so its schema is unchanged.

### The blind solve: not at launch

`judge_solve_options` would have to be a fixed list, for example
`%w[file_1+file_2 file_1+file_3 file_2+file_3 all]`, with `.keyed_solve`
mapping the key's `files` onto it. It isn't worth turning on at first:

- **On a two-file section the solve tells us nothing.** The only choice is
  "both files", so it always matches. Two files will likely be the common case.
- **What it measures is already enforced.** The quote check requires the
  key's quotes to cover 2 files, and the judge guidance rejects a section
  one file explains. A blind solve would add a measurement, not a guard,
  since `REJECT_SOLVE_MISMATCH_BELOW_PRINCIPAL` stays false.
- **It costs more than the setting.** A kind with `judge_solve_options`
  writes `JudgeSolve` rows, and the judge's outcomes for it omit evidence
  and reason (`JudgedGeneration`). The reply is parsed `log_raw: false`, so
  `[judge]` logs would show less. The admin page (`/admin/judge_solves`)
  renders `piece_a`/`piece_b` and would need a view for files.

Revisit if the sampled manual read (section 10) finds single-file flaws
getting through. A three-file section is where a solve could tell them
apart.

## 10. Cost, specs, snapshots, docs and stop conditions

### Cost

These are estimates at about 4 characters a token. Nothing here has been
measured.

- **Generation:** on a day the third slot draws `change_review`, its
  section is about 600–900 output tokens: up to 40 lines of code with JSON
  escaping, 3 paths, changed lines, and a key with 2–4 quotes. That replaces
  the third it displaced, which is about 300–450 tokens for a `security_review`
  or `challenge`. Net, about 300–500 more output tokens on those days and none
  on others.
- **Retries:** a retry regenerates the section at the same size.
- **Inputs:** the judge, the grader and each duck turn read about 400–600
  more input tokens on those days. The grader's day context is a cached
  system prompt, and the duck caches its system prompt too.
- **No new calls:** the blind solve is off and the key isn't checked by a
  provider.
- **Cap:** the generation call's output cap (`MAX_TOKENS`, 16,000 on Claude)
  isn't at risk.

Confirming these numbers takes one real generation forced to draw
`change_review`. Like the stored keys spec, it uses only a key the owner
holds, and the build asks before running it.

**What a refusal costs.** A planned section refused at the boundary is
handled like a rejection the judge never saw. It gets one retry with the
concept fixed (a rotating kind's `ROTATED_JUDGE_RETRIES`), then it is dropped
and recorded in `dropped_sections`. The day is then one section short, and
nothing in rotation makes up for it. The weekend single-stage path drops it
straight away. The refusal rate is therefore the number to watch (stop
conditions).

### Specs, written first

- **`spec/models/exercise_section/change_review_spec.rb`:** `.reject_unusable!`
  - for file count, each cap, blank and duplicate paths, and `file_3`'s
    both-or-neither rule
  - for changed-line resolution: a quoted line that resolves after Ruby
    re-indentation, one that matches nothing, and no resolved line in any file
  - for every answer-key rule in section 3: a quote from the wrong file,
    quotes covering one file, a path in `files` that isn't a section path,
    and blank fields
  - that a refusal message holds none of a sentinel planted in the key
- **`exercise_section_spec`:** thirds, registry order, `.answer_key_fields`,
  `.code_fields`, and the vocabulary in each language: 8 concepts on Ruby,
  the 5 data-modeling concepts on JavaScript, never empty.
- **`section_rotation_spec`:** `change_review` rotates and starves like any
  third, at every rung.
- **`daily_plan_spec`:** unchanged in what it pins. `DailyPlan` still reads
  no `KindDifficulty`.
- **Generation guidance:** one line per rung, stating the file range from
  section 5, checked through the snapshots below.
- **The JavaScript matcher:** a quote that differs from the formatted code
  only by `'`/`"`, a trailing `;` or a line break Prettier added matches; a
  changed line Prettier re-wrapped marks every line it spans; a quote under
  12 non-whitespace characters is refused.
- **Repeated concepts on JavaScript days:** a `section_rotation_spec`
  example where history repeats one data-modeling concept shows the third
  slot still rotating by kind, with nothing refused.
- **`code_highlight_spec`:** the changed class on the right lines; the same
  code with different `changed` gives different HTML (cache key); no
  `changed` gives byte-identical HTML to today's.
- **`section_context_spec`, `section_judge_prompt_spec`,
  `section_rendering_characterization_spec`:** a sentinel in every
  `answer_key` value never renders. The last one adds the key's text to
  `ANSWER_KEY_MARKERS`, as the stored keys spec does for its four kinds.
- **`FakeService::EXERCISE_PROBLEM_SET`** gains a `change_review` section
  with a usable key, so the request and system specs run it end to end.
- **`spec/system/change_review_phone_spec.rb`:** at 320px, three files show
  as open disclosures with their paths, the page doesn't scroll sideways, a
  changed line has `code-line-changed`, and a long wrapped line hides its
  alignment padding after a fold and reopen (`code-lines`).
- **`section_kind_guide` spec:** `SectionKindGuide` needs a summary, an
  example and a one-sentence `short` for the new key; the spec fails until
  they exist. The example says what the engineer sees and is asked, never
  what is wrong.
- **`claude_rules_spec`:** the new files match a rule's `paths:` (see Docs).

### Snapshots

- **New** generation prompt snapshots for a day that draws `change_review`:
  the fragment, the guidance and the key line.
- **New** review prompt snapshots: the section prompt and the day context
  with a `change_review` section.
- **New** section judge prompt snapshot for this kind.
- **`generation_prompt_pair_coverage_spec`** renders every reachable pair,
  so it gains this kind's pairs, and its "named by kind" check covers them.
- **Unchanged:** every existing snapshot. A default account's prompt, page
  and request snapshots must stay byte-identical (`planning.md`, "Daily
  kinds"). Any other snapshot diff is a stop condition.
- **The one existing page that changes** is Setup's Exercise mix, which lists
  every kind, so the new kind appears there. That diff is expected and
  reviewed by hand.

### Docs and rules

- **`docs/decisions/change-review.md`:** the decision, with the owner's
  decisions above. It covers:
  - no gate, with the rung shaping the problem
  - track-based availability as a future option, with the question it has to
    settle first
  - the JavaScript call
  - the blind-solve call
  - the refusal rule for a failed key
- **`.claude/rules/generation.md`:** one entry ("Change review"). Its
  `paths:` already match `app/models/exercise_section/**` and
  `spec/**/exercise_section/**`, so no path is added for the kind.
- **`.claude/rules/planning.md` and
  `docs/decisions/difficulty-targets-and-locks.md`:** unchanged. Nothing in
  the plan reads `KindDifficulty`.
- **`.claude/rules/pages.md`:** its server-side highlighting entry gains
  the changed lines and the cache key. Its `paths:` already match
  `code_highlight.rb` and `syntax_highlighting_helper.rb`.
- **Code notes:**
  - `docs/code-notes/app/models/exercise_section/change_review.md`: why
    changed lines are quoted, not numbered; why a failed key refuses the
    section
  - `docs/code-notes/app/models/code_highlight.md` (new): the cache key
- **`docs/file-map.md`:** the new kind and the body partial.
- **`config/locales/en.yml`:** `sections.change_review.name` ("Change
  Review") and the placeholder.

### Stop conditions

Stop and come back to the owner, without building further, if:

- an existing prompt, page or request snapshot changes, other than Setup's
  Exercise mix
- the measured generation run truncates, or `change_review` is refused at the
  boundary on both of its first two forced runs
- in the first 10 delivered `change_review` sections, more than 2 were
  dropped after the retry. Read `dropped_sections`; each drop costs a day a
  section.
- in a sampled read of the first 10 delivered sections, by the owner, as in
  the stored keys spec's option B, more than 2 had a flaw that one file shows
  on its own. The quote check and the judge are then letting single-file
  flaws through, and the blind solve (section 9) is the next step.
- any delivered file needs horizontal scrolling at 320px, or a file over 15
  lines reached the page
- in the first 10 delivered JavaScript `change_review` sections, more than 2
  were refused at the boundary for quote misses, which would mean Prettier's
  rewrites defeat the quote check
- anything in the build turns out to need a rung or a lock to decide whether
  the kind is offered

## 11. Ordering

1. The stored answer keys build merges first. This kind reuses its
   `answer_key` field shape for `code_review`, its quote check, its strip-site
   specs and `ANSWER_KEY_MARKERS`, and its review-context key line. Building
   `change_review` first would mean writing those pieces twice.
2. The `code_review` length cap (a separate issue) is independent and can
   land at any time. Its `.reject_unusable!` is the same kind of check as
   section 7 here, in another kind.
3. Then this build: the kind and its boundary, then its place in rotation,
   then the highlighting, then the page, then the judge and grading, each
   step test-first.
