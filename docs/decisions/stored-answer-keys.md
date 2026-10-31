# Stored answer keys

Built from `docs/stored-answer-keys-spec-2026-10-27.md`, which keeps the full
reasoning, and its plan, `docs/stored-answer-keys-plan-2026-10-27.md`. This
record covers the first PR: the keys are stored and read by nothing. The
second PR lets the grader read `code_review`'s keys, and later PRs turn on the
other three kinds one at a time; each kind's half is added here when it
merges.

## Why

`code_review`, `security_review`, `plan_review` and `pseudocode_to_code` ask
the generator to plant something: a defect, a vulnerability, 2-3 plan
flaws, a requirement a plan could miss. Until now nothing kept what was
planted. The grader had to work out from the snippet or plan what the
planted point was, and when it guessed wrong it graded the answer against a
different problem. Nothing recorded the guess, so a wrong grade of that kind
couldn't be told apart from an honest miss.

`design_comparison` and `ambiguity_hunt` already stored their keys, and the
places a key must never reach already read the field list generically.

## What is stored

Each of the four kinds stores its key under `answer_key`, in its own shape:

| Kind | `answer_key` |
|---|---|
| `code_review` | `issue` (quoting the code), `why_it_matters`, `fix` |
| `security_review` | `vulnerability` (quoting the code), `exploit`, `mitigation` |
| `plan_review` | `flaws`: each a `category`, a `flaw` (quoting the plan) and a `pushback` |
| `pseudocode_to_code` | `missable_requirements`: 1-3 requirements and what a plan that misses one gets wrong |

**One field name.** Reusing `answer_key` keeps
`ExerciseSection.all_answer_key_fields` at two entries, so every strip site
covers the new keys unchanged. The trade-off is that `answer_key` now holds
different shapes in different kinds: `design_comparison`'s is
`{better, deciding_fact, …}`, and it is shown after review on purpose, while
the four new keys are shown nowhere. Code that reads a key reads it through
its own kind, never by the field name alone.

**Quotes, not line numbers.** A key quotes code or plan text in backticks.
Ingest re-indents code once, and Prettier can re-wrap JavaScript, so a line
number written by the provider can point at the wrong line by the time
anyone reads it.

## An unusable key keeps the section

`ProblemSetIngest#clean_planted_keys!`, right after the unusable check,
stores each keyed section's key cleaned through its kind's
`.normalize_planted_key`, or deletes an unusable one, and never refuses the
section over it. It cleans a section that lost its slot too, since a judged
day keeps every planned kind and can ship one an unplanned section beat. Cleaning is its own step, not part of `.reject_unusable!`,
so a kind that overrides that hook can't skip it by forgetting `super`
(owner's decision, 2026-10-28). A keyed kind extends `PlantedKey::Kind`,
whose hooks raise until the kind answers them. The key only helps grading, and the grader falls back to today's
behavior for a section without one, so dropping a section or spending a
retry over a field the engineer never sees would cost more than it saves.

### A key past the length limit is dropped, never cut

The owner decided on 2026-10-30, after the first triage run:

- **The limit is 1,500 characters a field** (`PlantedKey::MAX_LENGTH`, up
  from 500). Under the old limit, ingest cut a long field to exactly 500
  characters ending in `...`. In the four sections the run wrote out, 8 of
  12 key fields were cut that way, so the largest stored field was 500, and
  the stored keys can't show how long the provider wrote. The fields that
  weren't cut ran 373 to 467 characters. The solver's replies on the same
  sections were never cut, and ran 359 to 770, the longest a fix that wrote
  a migration in full. 1,500 is about twice the solver's longest reply and
  about three times the longest uncut key field, so a few sentences with
  inline code fit, and a field past it is no longer a few sentences. Four
  uncut fields is a small sample, so the fresh set of 8 drafted under the
  new limit is also the check on it.
- **The guidance asks for a few sentences a field,** in each keyed kind's
  schema line.
- **A field past the limit drops the whole key.** A cut field can lose the
  part grading needs, such as the second gap a key names. The section keeps
  today's keyless grading, and its key note reads `too_long`, logged with no
  key text. A list key (`plan_review`'s flaws, `pseudocode_to_code`'s
  requirements) is dropped whole when one entry that survives cleaning is
  too long. An entry cleaning already removes (a flaw with no pushback, an
  entry past the list's cap) is never measured, and the key keeps the
  rest. The multi-file
  key's `evidence` entries, stored from the multi-file launch on, follow
  the same rule.
- **Keys stored at the old limit are recognisable.** `String#truncate(500)`
  wrote a field of exactly 500 characters ending in `...`, and a field that
  ended there by chance is close to impossible. A key with any such text
  field, on a day generated before this change deployed, was cut. PR 2
  grades a section with that key as keyless.

## Is the key right?

Two checks, neither of which changes a key:

- **The quote check at ingest.** Each backticked quote in a code review's
  `issue`, a security review's `vulnerability` or a plan review's `flaw` must
  appear in the code or plan as shown, with all whitespace removed on both
  sides, since the Ruby formatter adds spaces the provider never wrote. A
  quote under three characters is left unchecked, and a backtick inside a
  quote (a JavaScript template literal) splits it, a known limit. A key with
  no quote at all counts as a miss (owner's decision, 2026-10-27). It
  catches a key that quotes code that isn't there, not one that quotes the
  right line and misreads it. Every keyed winning section logs one
  `[planted_key]` line with its kind, language, outcome (`ok`, `missing`,
  `too_long` or `quote_missing`), `attempt` (`draft` or `retry`) and the day's
  `code_review_mode`. The threshold is counted from those lines: more than 2
  `quote_missing` in the first 10 drafted Ruby sections of a kind that
  quotes (`code_review`, `security_review`, `plan_review`) stops the work,
  and `missing` is reported beside it (owner's decision, 2026-10-28). A
  `too_long` line never reached the quote check, so it doesn't count toward
  those 10. It has a rule of its own: more than 2 `too_long` in the first 10
  drafted Ruby sections of a keyed kind also stops the work, and the owner
  decides between raising the limit, tightening the guidance and accepting
  the rate (owner's decision, 2026-10-30).
- **A sampled read.** The owner reads the Ruby `code_review` keys from real
  days, through the key sheet (`export_review_baseline.rb --key-sheet`),
  which carries the problem and its key and nothing about the owner's
  answers. About 5 sections a kind are read; a kind with fewer waits.

### The rarer kinds are read from drafts

The owner is the app's only user, and their days are mostly two sections, so
`security_review`, `plan_review` and `pseudocode_to_code` could take months to
reach 5 keyed sections. Adding those kinds to the owner's own days would
make progress that isn't real. The owner decided on 2026-10-28:

- **Drafts, not real days.** `script/draft_key_samples.rb` drafts those
  three kinds through the production retry route, ingest and judge,
  and writes no day or history. It runs on the owner's machine against a
  local database, never against production, and every billed run waits for
  the owner's approval of its call count and cost. It logs no `ApiUsage`
  row. A logged row couldn't block a real day anyway: only house-key trial
  checks and the Account page's spend total read those counts.
- **A colleague reads them.** The owner can't judge those keys reliably, so
  a colleague the owner chooses reads the drafts. A kind with no available
  reader stays off.
- **The read is the main check.** For those three kinds, the calibration
  fixtures are a guard against a grader misusing a key, and the
  read decides whether the keys are right.
- **Real graded sections, if any.** Only sections generated after this PR
  deployed carry a key. The owner's graded sections of the three kinds,
  counted with an approved read-only query, get the keyed-against-unkeyed
  regrade as a small sample if any carry a key. That sample is reported, not
  held to the systematic-movement rule, since it is too small for it.

### The grader turns kinds on one at a time

The second PR turns on `code_review` alone, so it doesn't wait on the three
drafted kinds (owner's decision, 2026-10-28). It starts once the
`code_review` read between the PRs is done and the token cost below has been
measured. `security_review`, `plan_review` and `pseudocode_to_code` stay off
until their drafts are read, and each joins in a PR of its own, with its own
calibration fixture and the small graded-section sample above.

Drafts show that the generator plants a correct key for these kinds. They
don't show that keys hold up on the owner's real days, so the first real
section of each kind is checked through its `[planted_key]` line.

The stability export (`export_review_baseline.rb` without `--key-sheet`)
keeps the four keys. It reads only submitted, reviewed days, it already holds
the answers and the older keys, and the second PR's measuring regrades from
it with and without the key (owner's decision, 2026-10-28).

### A blind solve screens the `code_review` drafts

The owner decided on 2026-10-30 to add a triage step for `code_review`.
About 30 sections are drafted with the drafts script, toy and single-file,
cycling through the three modes. Each one is solved by a separate call that
never sees the key, and the script compares the solver's quoted lines with
the key's in Ruby: agree, disagree or unlocated. The disagreements and up to
three agreements, one per mode that has one, go to the key sheet outside the repository for the owner to read.
Every run waits for the owner's approval of its call count and cost.

- **Agreement is screening only.** A solver that finds the same lines as the
  key doesn't show the key is right. The generator and the solver can share
  a mistake, the more so within one model family, and the judge (Sonnet 5.5,
  the default solver too) has already kept each section. A disagreement
  doesn't show the key is wrong either: the solver may have found a second
  flaw, or misread the code. Triage only says which keys to read first. The
  quote threshold and the owner's read of real-day keys stay the gate for the
  second PR.
- **The solver may run on a different model than the generator.** It can use
  any priced Claude model on the owner's own key, Sonnet 5.5 by default
  against the generator's Opus 5.5. It can use another provider only with a
  key the owner holds for that provider.
- **The key never reaches the solve.** The solve is a pre-submission AI
  context, so its prompt is built from the section with every answer-key
  field and server stamp removed, through the same step as the judge's
  prompt. A sentinel spec checks every request body. The comparison never
  puts the key and the reply in one prompt. The reply is never stored in
  the database or sent to another prompt; it goes only to the key sheet
  file outside the repository. The prompt lives in `script/`, out of the
  app's reach.
- **This is not the judge's blind solve.** The judge solves only design
  comparisons, live (`JudgeSolve`). This triage is an offline script, and
  turns nothing on.

## Before the grader reads them

The second PR changes grading, so these hold from now:

- **`RUBRIC_VERSION` stays unchanged** only if keyed and unkeyed grading show
  no systematic rating movement. That is measured on this PR's keyed days,
  with the second PR's code from its branch, before it merges, so no
  evidence reader sees a keyed grade first.
- **Systematic movement** is at least 3 sections in one kind whose typical
  rating differs between keyed and unkeyed grading in the same direction,
  beyond the unkeyed run's own run-to-run change on those sections.
- **A different finding** meets the main point only when it is at least as
  serious as the keyed one; plan review's main point follows the same rule.

## Cost

About 60-150 more output tokens per keyed section on the generation route,
by the spec's estimate. The owner decided on 2026-10-28 to measure it from
the `generate_exercise` usage rows of the week before and the week after this
PR deploys, rather than with extra billed calls. The second PR waits for that
measurement.
