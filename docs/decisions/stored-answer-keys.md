# Stored answer keys

Built from `docs/stored-answer-keys-spec-2026-10-27.md`, which keeps the full
reasoning, and its plan, `docs/stored-answer-keys-plan-2026-10-27.md`. This
record covers the first of two PRs: the keys are stored and read by nothing.
The second PR lets the grader read them, and its half is added here when it
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
stores each winning section's key cleaned through its kind's
`.normalize_planted_key`, or deletes an unusable one, and never refuses the
section over it. Cleaning is its own step, not part of `.reject_unusable!`,
so a kind that overrides that hook can't skip it by forgetting `super`
(owner's decision, 2026-10-28). A keyed kind extends `PlantedKey::Kind`,
whose hooks raise until the kind answers them. The key only helps grading, and the grader falls back to today's
behavior for a section without one, so dropping a section or spending a
retry over a field the engineer never sees would cost more than it saves.

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
  `[planted_key]` line with its kind, language, outcome (`ok`, `missing` or
  `quote_missing`), `attempt` (`draft` or `retry`) and the day's
  `code_review_mode`. The threshold is counted from those lines: more than 2
  `quote_missing` in the first 10 drafted Ruby sections of a kind that
  quotes (`code_review`, `security_review`, `plan_review`) stops the work,
  and `missing` is reported beside it (owner's decision, 2026-10-28).
- **A sampled read.** The owner reads the Ruby `code_review` keys, and a
  colleague the owner chooses reads the other three kinds, from the key
  sheet (`export_review_baseline.rb --key-sheet`), which carries the problem
  and its key and nothing about the owner's answers. About 5 sections a kind
  are read; a kind with fewer waits. The owner decided on 2026-10-28 to let
  the rarer kinds come up on their own, so the second PR turns keys on kind
  by kind.

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
PR deploys, rather than with extra billed calls.
