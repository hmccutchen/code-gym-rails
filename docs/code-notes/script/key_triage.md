# `KeyTriage`

The blind-solve triage for drafted `code_review` keys, run as
`script/draft_key_samples.rb code_review OUT_PATH --triage`. A second call,
which never sees the key, solves each kept draft, and Ruby compares what it
quotes with what the key quotes. Disagreements tell the owner which keys to
read first. Agreement only screens: the generator and the solver can share
a mistake, and the real-day read stays PR 2's gate
(`docs/decisions/stored-answer-keys.md`, "A blind solve screens the
`code_review` drafts"). `KeySampleDrafts` makes the calls; this module holds
the solve prompt, the comparison and the report.

## What the solver sees

`.solve_prompt` renders the section through `SectionJudgePrompt.visible`, the
judge's own strip of answer keys, server stamps and the kind's
`.judge_hidden_fields`, so the rule for what a pre-submission call may see
lives in one place. `HIDDEN_FROM_SOLVER` drops two more fields:

- `teaching_note`, which the page keeps locked until the section is
  answered (`dashboard/_teaching_hint`) and which the generator writes as a
  pointer to its key.
- `concept`. The page does show it before answering, in the concept
  reference's summary, but the generator chose that label to match its key,
  so a solver given `n_plus_one` is steered toward the key's flaw. Hiding it
  makes the solve stricter than the engineer's view, so agreement means more.

The prompt text lives here in `script/`, so no path in the app can send it,
and `spec/script/key_triage_spec.rb` pins it with prompt snapshots.

The solve is its own purpose, `triage_solve`, kept out of
`CallProfiles::BY_PURPOSE` because `ApiUsage::PURPOSES` must equal that
table's keys and no usage row is ever written for it. `KeySampleDrafts.service`
routes it to the solver model at `SOLVER_EFFORT`, `high`. The model is the
judge's, Sonnet 5.5, unless `--solver-model` names another model on a
`ClaudeService::MODEL_FOR_PURPOSE` route (`SOLVER_MODELS`): Haiku 4.5 is
priced but on no route, so no effort setting has been used with it here.
The request sets no token cap,
since a capped call turns thinking off and Opus 5.5 has no off setting. The
reply is parsed with `log_raw: false`, checked by `.reply` for a text
`issue` and `fix`, and written only to the output file. `.reply` keeps each
field whole rather than reusing `PlantedKey.fields`, whose 500-character cap
would drop a quote past it and cut the fix the owner reads. The solve uses only
the owner's Anthropic key; another provider isn't built.

## The comparison

`.compare` finds each backtick quote, in the solver's `issue` and in the
key's quoted texts (`.quoted_key_texts`), in each of the kind's
`.key_context_fields` with `KeyQuote.find`. A quote shorter than
`PlantedKey::MIN_QUOTE_LENGTH` once normalized is skipped, since it would
match almost anywhere, and `KeyQuote.find` places a quote only when the
field holds it once. Then:

- **agree:** a solver quote's line range overlaps a key quote's range in the
  same field
- **disagree:** both sides have quotes the code holds, and none overlap
- **unlocated:** either side has no quote the code holds

A quote of three or more characters can still sit inside a longer name
that the code holds once, and a wide quote agrees with anything inside it,
so an agreement can be wrong. Each entry records `solver_lines` and
`key_lines`, the lines each side's quotes landed on by field, so the owner
sees how wide an agreeing match was and which side an unlocated section
lacks.

## What it writes

`.sheet_sections` keeps every disagreement and unlocated section, plus the
first agreement of each mode that has one. A mode with no agreement gets
none, `.summary` names it, and no extra call is made to fill it. `.summary`
prints the counts overall and by mode, with no section text, on the terminal
and in the file.
