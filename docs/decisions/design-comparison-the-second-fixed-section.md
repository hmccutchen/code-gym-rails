# Design comparison, the second fixed section

every day holds
`code_review` and `design_comparison` (`ExerciseSection::DesignComparison`,
`default_daily? true`), each in a slot of its own ahead of pattern, third
and fourth. Those are the default daily pair; since `DailyKinds`
(`docs/decisions/daily-kinds.md`) the pair is a per-user value and the
slots come from `ExerciseSection.layout(daily:)`. A day still holds at most `ExerciseSection::MAX_SECTIONS` (4), so
a day of N sections has N − 2 optional slots, which pattern, the thirds
and the fourths compete for on staleness. With five slots, a payload with
a shape in every slot would resolve to five sections: `ProblemSetIngest`
drops the slots the plan left empty whenever a payload would resolve past
the maximum, and `ExerciseSection.resolved_keys` caps a stored row at
`MAX_SECTIONS`, daily kinds first, so a requested section is never the one
cut. Below the maximum an unrequested extra is still kept and warned about.

**The task.** Two working pieces of code that meet the same stated
behavior, retries and failures included, and differ on one design
principle, the tagged concept. The engineer picks the piece the stated
system should use and says which stated fact decides it. The rung sets
where that fact sits: in the question, pointing at a piece, at junior; in
the question as a requirement, not a piece, at mid_level; in the system
description at senior; and in a scenario where both pieces carry a real cost
at principal_engineer. Any difference other than the tested principle is a
defect, so the guidance asks for surface parity. No scaffold and no
teaching note, since either would point at the answer.

**A/B order is the server's.** The provider returns `better_piece` and
`other_piece`; the kind's `.arrange!` hook, which ingest calls on each
resolved section after `.reject_unusable!`, rolls `POSITION_WEIGHTS`
through `WeightedRoll`, writes `piece_a`/`piece_b`, sets
`answer_key.better`, and deletes the canonical fields. There is no
"must differ from the stored order" rule, which with two pieces would
always swap. `.reject_unusable!` refuses a missing, blank or non-string
piece, a piece past `MAX_PIECE_LINES` (24 non-blank lines), and an answer key missing any
of `deciding_fact`, `principle`, `why_other_fails`. Specs pin the roll to
B (`spec/support/weighted_roll_position_default.rb`), which sorts after
`real_source_default.rb` on purpose. `script/report_answer_positions.rb`
is the read-only check on A/B balance; no log line records a position.

**The answer key never leaves the server before review.** `answer_key` is
the kind's `.answer_key_fields`, so `ExerciseSection.without_answer_keys` keeps it out of
`[difficulty_diagnostics]`, `judge_section` keeps it from the judge, and
`SectionContext.render` gains only `piece_a` and `piece_b` (scenario and
question were already there). The page shows the key, as "What decides
it", only once the section has a review.

**Answer storage.** `"pick:a\n" + reason` in the existing answer slot, as
Parsons stores `"order:…"`. The kind owns `parse_answer`, `encode_answer`
and `answered?`: a valid pick and a non-blank reason of any length, since
judging a short reason is the grader's job. The form is a radio fieldset and a
labelled textarea; the `comparison-answer` Stimulus controller writes
them into the hidden `data-field` textarea, which saves like any other answer; the server's
reply says whether it counts, as for every kind. `review_context` decodes the
answer ("Picked: B. Reason: …") and hands the grader the key; the grading
note names the main point and essential pieces, caps a matching pick with
a vague reason and the other pick with a sound reason at developing, and
never restates the rubric's levels.

**Vocabulary.** `.narrow_vocabulary` is an allowlist built from the
existing constants (the code-smell, OO-design, module-design and
domain-modeling groups, the data-modeling group minus `DEFERRED_CONCEPTS`,
the TypeScript concepts, and the concepts in `HOSTED_CONCEPTS`),
intersected with the day's language vocabulary, minus `TRADEOFF_CONCEPTS`
unless the rung is principal_engineer. Concepts whose worse piece would be
incorrect stay out. `missing_constraint`, `unsafe_migration` and
`wrong_cardinality` were deferred after the 2026-10-01 real-draft check,
where a missing_constraint draft's pieces behaved differently under the
scenario's own concurrent writers and bulk insert and the judge kept it;
each returns only after a comparison run shows behavior-equivalent
drafts. The judge guidance names behavior that differs under any
condition the scenario states as a reasoning failure. Callers that know the rung pass it (`GenerationPrompt#generation_guidance_for`,
`can_host?` through the prompt's per-kind rungs, the kind-difficulty
diagnostics, `GenerationLadders.for`); `DailyPlan` passes none and gets the strictest
list; `ConceptHosts` unions every rung unless handed a `difficulty`, which
`LadderCoverage` passes so every kind is read at its rung. History
records under the day's language bucket. Each concept-group guidance line
for a group this kind hosts names its design_comparison idiom once;
silent correctness and meta skill are not hosted, so their lines do not.

**The judge solves it blind.** `.judge_solve_options` (`%w[a b]`) adds a
required `better` field to this kind's verdict schema and to
`JudgeVerdict.parse`, and `.judge_guidance` adds the kind's contract to the
judge prompt. `JudgedGeneration` compares the solve with the key through
`.solve_matches_key?` and logs `[judge_solve_mismatch] user=… section=…
rung=…` with neither the key nor the pick; the outcome carries only
`solve_matched`, one boolean per judged version. Rejecting on a mismatch
below principal_engineer, as underdetermined, sits behind
`JudgedGeneration::REJECT_SOLVE_MISMATCH_BELOW_PRINCIPAL`, which stays
false until `script/compare_models.rb judge` has run on real drafts and a
person has read the disagreements; principal_engineer never rejects on a
mismatch. The judge may reword the title, scenario and question, which is
where the deciding fact lives, so an edit to this kind is judged once more
(`.rejudge_edits?`, true only here): if that judgment rejects, cannot
answer, or solves the edited section against the key, the unedited draft
ships and the outcome records `edit_reverted: true`. It costs one judge call
only when this kind is edited, and `JUDGED_GENERATION_BUDGET` adds one
judge call's worst case for it. Because the solve makes the judge's own words an answer
candidate, this kind's outcomes omit evidence and reason, its reply is
parsed with `log_raw: false`, and an unreadable response body that starts
like JSON is logged by size only, for every call. Known limit: the judge
sees one section, so it cannot check that a shared concept's comparison
avoids the code review's scenario. Its guidance asks only what it can
check inside the section: a section that restates a defect to find,
rather than offering a choice between two working designs, is a
scope_mismatch.

**Blind solves and reverted edits are kept.** Since the answer-key trust
work (`docs/answer-key-trust-spec-2026-10-22.md`, stage 1 plan
`docs/answer-key-trust-stage1-plan-2026-10-22.md`), every judge pass on this
kind is written to `judge_solves`: the section exactly as the judge saw it,
its key, the judge's pick, whether they matched, and why a failed solve
failed (`JudgeVerdict::Invalid`'s message, which never quotes the pick).
`JudgedGeneration` still writes nothing; it hands back one
`JudgedGeneration::Solve` per pass on `AiService::JudgedSet#solves`, never
inside `outcomes`, and both generation jobs record them with the set.
`shipped` comes from the control flow, which already knows which attempt
settled and whether an edit was kept. An edit check whose edit was thrown
away carries `edit_reverted` and its `revert_reason` (`solve_mismatch`,
`judge_rejected` or `judge_failed`), and the shipped original sits in the
same attempt's row with `edit_check: false`. The
`[judge_solve_mismatch]` log line and `outcomes[:solve_matched]` are
unchanged, and `REJECT_SOLVE_MISMATCH_BELOW_PRINCIPAL` stays false until a
person has read the disagreements this record makes readable.

**The replay.** `script/replay_design_comparison_solves.rb` judges every
stored design comparison with today's judge and writes `source: "replay"`
rows, skipping a section version it already judged (same exercise, section
and `section_digest`) unless told to re-judge. It defaults to a dry run that
prints the count and the cost bound. `--synthesize N` writes
`source: "synthetic"` rows for sections generated only for measurement,
which no engineer ever saw. Live rows say what the judge thought at the
time; replay rows say what today's judge thinks of the same shipped section.
Only live and replay rows count toward a decision; synthetic ones only
corroborate.

**Hidden unless proven.** A row holds a key, so `JudgeSolve.readable` is the
only way any page reads one, and it starts from hidden. A row is readable
when it is synthetic, when it carries a `never_shown_reason`
(`replaced_by_retry` or `section_dropped`, recorded when the row is written,
for versions whose pieces never reached the engineer), or when the row's own
section has been reviewed on its exercise's response and the row belongs to
the set that was reviewed (its `set_generated_at` is the exercise's
`generated_at`, so a regenerated set's old rows stay hidden). Everything else stays
hidden, including an unshipped row with no reason. A reverted edit's edited
text and the pre-edit draft of a kept edit have no reason on purpose: an edit
changes only the title, scenario and question, so both carry the pieces and
key the engineer has. `shipped` takes no part in the rule, so a wrong
`shipped` value can't leak a key. The reasoning is in
`docs/code-notes/app/models/judge_solve.md`.

**Reading `/admin/judge_solves`.** The page, linked from
`/admin/suggested_concepts`, is for an admin in `ADMIN_EMAILS`.
- The header counts readable rows only, by source: solved, matched,
  mismatched and unsolved; reverts by reason; and two call tables, one for
  mismatches and one for matched records. A call table counts each section
  version once (rows sharing a `section_digest`, the latest call winning, under
  that row's source) and leaves out unsolved rows and principal engineer,
  where disagreement is already tolerated. One more line, "withheld pending
  review: n", counts hidden rows with no breakdown at all. The page computes
  no bound and names no branch; you apply the spec's decision rule yourself,
  from the live and replay columns together.
- `source` picks live (the default, what shipped), real (live plus replay,
  what the decision rule counts), replay, synthetic or all. `show` picks
  mismatches and reverts (the default), reverts only, a random matched
  sample of `n` uncalled records (15 by default, never synthetic), or all.
  `call` narrows to uncalled records or one call.
- Entries list reverted edits first, then mismatches, newest first. Each
  shows its metadata, the problem, both pieces, the key, the judge's pick
  and a form offering only the calls that fit (`key_right`, `judge_right` or
  `both_defensible` on a mismatch; `key_right`, `both_wrong` or
  `both_defensible` on a match) plus a note. A reverted edit shows the
  shipped original's prose beside the edited prose once both are readable,
  and a live row links to its replay and back.
- A hidden row shows only as "waiting for the engineer's review" with its
  date, source and rung, in a list of its own that the outcome filters and
  ordering don't touch, and a save on it is a 404.

**The reference stays closed.** A concept's reference opens on its own on
first exposure for every other kind; for this one it names and illustrates
the principle the grade asks for, so `.reference_opens_before_answer?` is
false and it stays closed until the engineer opens it.

**Setup.** The Exercise mix groups the user's daily kinds under "In every set"
(difficulty only), and gives pattern, and any default kind that is not
daily, a group of its own.
