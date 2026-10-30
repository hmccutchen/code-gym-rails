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
lives in one place. It also drops `concept`, which the judge sees but the
page doesn't show on a `code_review` before review: a concept such as
`n_plus_one` would point the solver at the flaw. The prompt text lives here
in `script/`, so no path in the app can send it.

The solve is its own purpose, `triage_solve`. `KeySampleDrafts.service`
routes it to the solver model, Sonnet 5.5 unless `--solver-model` names
another model with a price in `ClaudeService::PRICE_PER_MILLION`, and keeps
the effort of that model's existing route. The request sets no token cap,
since a capped call turns thinking off and Opus 5.5 has no off setting. The
reply is parsed with `log_raw: false`, checked by `.reply` for a text
`issue` and `fix`, and written only to the output file. The solve uses only
the owner's Anthropic key; another provider isn't built.

## The comparison

`.outcome` finds each backtick quote, in the solver's `issue` and in the
key's quoted texts (`.quoted_key_texts`), in each of the kind's
`.key_context_fields` with `KeyQuote.find`. A quote shorter than
`PlantedKey::MIN_QUOTE_LENGTH` once normalized is skipped, since it would
match almost anywhere. Then:

- **agree:** a solver quote's line range overlaps a key quote's range in the
  same field
- **disagree:** both sides have quotes the code holds, and none overlap
- **unlocated:** either side has no quote the code holds

`.find` returns a quote's first match, so a quote that appears twice is
placed at its first appearance. Two quotes on the same line still overlap,
so the cost is a rare false disagreement, which the owner reads anyway.

## What it writes

`.sheet_sections` keeps every disagreement and unlocated section, plus the
first agreement of each mode that has one. A mode with no agreement gets
none, `.summary` names it, and no extra call is made to fill it. `.summary`
prints the counts overall and by mode, with no section text, on the terminal
and in the file.
