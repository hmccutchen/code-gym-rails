# Proportionality: a proposed design comparison concept

Status: proposal. Nothing here is wired in. The concept is in no vocabulary,
in no kind's allowlist and in no prompt. The six judge fixtures under
`spec/fixtures/judge/design_comparison_proportionality_*.json` and the
`judge_concept` mode of `script/compare_models.rb` exist so the judge
comparison can run before anything ships.

## The concept

**Definition.** A change should be the size of the problem the scenario
states. Machinery the scenario gives no reason for has a cost even when it
works.

In a design comparison, one piece fixes the stated problem directly. The other
is correct and behaves the same, but adds more than the scenario justifies: an
extra layer, a guard against input the scenario says cannot arrive,
configuration nobody asked for, or retries or caching with no stated need. The
answer key's `why_other_fails` names what the extra machinery costs and why it
does not fit. It never names a bug, because there is none.

## The vocabulary-size argument

CLAUDE.md asks a new concept to earn its place: it must not be an existing
concept under another name, and the grader must be able to find something
definite in a section that carries it.

**Why it is not an existing concept under another name.**

- `shallow_module` and `pass_through_method` are two specific shapes of a
  needless layer. Proportionality judges size against stated need whatever
  the shape: a retry loop around a local file read or a configurable sort
  order nobody asked for is neither a shallow module nor a pass-through.
- `temporal_decomposition` splits code by the order it runs in. That is a
  question about where the seams go, not about how much is built.
- `open_closed` rewards adding an extension point for a change that is
  coming. Proportionality asks whether that change was ever stated, so the two
  can disagree about the same code, which is the point of having both.
- `scope_creep` is about a plan's scope. It lives in the language-independent
  `plan_review` bucket, which design comparison cannot draw from.
- `unjustified_constant` is one value nobody justified, also in `plan_review`.
- `cognitive_load`, `build_vs_buy` and `caching_strategy` are architecture
  concepts, in a bucket design comparison cannot draw from, and the last two
  are tradeoff concepts with two defensible sides at every rung.
- `speculative_generality`, Fowler's smell name, was considered. It covers
  abstraction built for a future need and leaves out a guard against harmless
  input or a retry nobody asked for.

**Why a deciding fact can be stated in a scenario.** Whether machinery is
needed is a fact about the system, and the code cannot show it: "the export
runs once a month", "this field is only ever set by our own admin form", "the
rates file ships with the app and is read from local disk". A section states
that fact, and the reason the engineer gives is graded against it. That is
also why the fact must never be readable from the code alone: two correct
pieces look the same until the scenario says what the system needs.

## Draft guidance line

Drafted in the shape of the existing concept-group lines in
`AiService#build_exercise_prompt`. It is not in any prompt. The
`judge_concept` mode appends it to the drafts it asks for, so the comparison
judges sections written under the line the follow-up would ship. Change it
here and the next run reads the new text.

<!-- draft-guidance:start -->
- The proportionality concept names whether a change's size and machinery match the problem the scenario states. A section tagged with it must state the fact that decides how much the problem needs (how often the code runs, where its input comes from, what has or has not been asked for) in its scenario or question, never only in the code. Both pieces must be correct and behave the same under every condition the scenario states; the larger one adds something the scenario gives no reason for: an extra layer, a guard against input the scenario says cannot arrive, configuration nobody asked for, or retries or caching with no stated need. Take the subject from validation, caching, retries, abstraction layers, configuration, feature flags, input handling or data shaping, never from concurrency, races, locking or transactions. The answer key's why_other_fails names what the extra machinery costs and why it does not fit, never a bug. A design_comparison shows the direct piece and the larger one; at junior the deciding fact sits in the question, at senior in the system description, and at principal_engineer both pieces carry a real cost that the stated facts still settle.
<!-- draft-guidance:end -->

## Known tension with the judge's surface-parity rule

The design comparison judge guidance rejects a section as a reasoning failure
when a piece can be picked by "clearly shorter code". The larger piece in a
proportionality section is longer by construction. The six fixtures keep the
difference to a few lines, but a judge that always picks the shorter piece
would agree with every one of them. The comparison should be read with that in
mind: agreement on these fixtures does not show the judge reasoned from the
scenario. A follow-up could add fixtures where the stated facts justify the
larger piece, which this concept's definition does not yet allow.

## What adding it to the vocabulary would reach

Checked against the code on 2026-10-07. Adding `proportionality` to
`RAILS_CONCEPTS` and `JS_CONCEPTS`, with design comparison not hosting it,
still reaches:

- **Other kinds' prompts.** `ProblemSetIngest.selectable_vocabulary_for` hands
  the language vocabulary to code_review (application_code and test_file
  modes), pattern and challenge, so their vocabulary lines change in every
  prompt snapshot. Parsons gets it too unless it joins a group in
  `ExerciseSection::ParsonsProblem.excluded_vocabulary_keys`; the
  module-design group is one. Schema-review code_review, architecture,
  security_review and the fourth kinds draw other lists and would not see it.
- **Learn.** The index and `LearnController#show` list every concept in the
  language vocabulary, the "Write up the rest" count grows, and drills accept
  it. Progress lists it too.
- **Mastery.** Any section tagged with it records a `ConceptMastery` row, so it
  enters reinforcement, retention checks and the shared-concept rule like any
  other concept.
- **Setup.** The ladder coverage counts on Setup grow for each kind that can
  host it, so `spec/fixtures/page_snapshots/setup.html` changes for existing
  accounts.
- **Not rotation.** `SectionRotation` picks kinds, never concepts, so which
  kinds fill a day does not change.

There is no kind-only vocabulary for a language-bucket kind. Ingest validates
a design comparison's concept against the language vocabulary, and mastery
filters rows by it, so hosting the concept in design comparison alone would
need new machinery rather than a list entry.

## Run results, 2026-10-09

Both runs the follow-up asks for are done. The commands were
`script/compare_models.rb judge_fixtures` and
`judge_concept 1 proportionality 2`, billed to a local `ANTHROPIC_API_KEY`.

**The six drafts read well.** `judge_concept` drafted two sections per rung
on `claude-opus-5-5` (41,642 in / 17,752 out, $0.5216) under the guidance
line above, unchanged. Reading each draft's title, scenario and question:

- Each states the deciding fact where its rung requires — in the question at
  junior, in the system description at senior, and at principal_engineer in a
  scenario where both pieces carry a real cost that the stated facts still
  settle.
- The scenarios vary across both flavor pools rather than converging on one
  setting.
- None reads as a defect hunt. The larger piece is correct in every one of
  them; what it adds is machinery the scenario gives no reason for, which is
  what the concept is for.

So item 3 below is met: the drafts are good enough to host the concept in
design comparison.

**The judge agrees, on Sonnet.** The production judge route kept all six and
solved all six blind with a matching pick ($0.0494). Haiku rejected 3 of the
6 — one junior as `scope_mismatch`, both principal_engineer as
`reasoning_failure` — while solving all six correctly ($0.0219). That is the
same pattern `judge_fixtures` shows elsewhere and is a reason to leave the
judge on Sonnet, not a finding about this concept.

**Read with the surface-parity caveat above.** Sonnet's six matching solves
do not show it reasoned from the scenario, because picking the shorter piece
would have produced the same six. The fixtures where the stated facts
justify the larger piece, which that section calls for, are still the
missing evidence.

**The six hand-written fixtures, which `judge_fixtures` runs.** These are
`spec/fixtures/judge/design_comparison_proportionality_*`, two per rung, and
they are the half of the evidence that is not the model's own drafts. On the
production route every one came back as the fixture expects, with a matching
blind solve:

| Fixture | Expected | Sonnet 5.5 | Haiku 4.5 |
| --- | --- | --- | --- |
| `junior_grocery_sort` | keep | keep, solve match | keep, solve match |
| `junior_rates_file` | keep | keep, solve match | reject `reasoning_failure`, solve match |
| `senior_library_reminder` | keep | keep, solve match | keep, solve match |
| `senior_statement_export` | keep | keep, solve match | reject `scope_mismatch`, solve match |
| `principal_pasted_list` | keep_or_edit | keep, solve match | error, reply truncated at 1,200 output tokens |
| `principal_rate_quote` | keep_or_edit | keep, solve match | reject `reasoning_failure`, solve MISMATCH |

Sonnet: 6/6 as expected, blind-solve agreement 6/6, no rejections. Haiku: three
false rejections and one truncated reply, and the one blind-solve mismatch in
the whole set. Read for disagreements, the two models disagree on four of the
six, and every disagreement is Haiku refusing or failing a section Sonnet kept
— the same shape the rest of `judge_fixtures` shows, and the same reason to
leave the judge on Sonnet. The single mismatch sits at principal_engineer,
where `REJECT_SOLVE_MISMATCH_BELOW_PRINCIPAL` never rejects on a mismatch
anyway, so it would change nothing even with that switch on.

Taken together with the drafts, the concept reads as hostable on the
production route; nothing here argues for the switch or for a different judge
model.

**The guidance line is unchanged.** It is edited only when the drafts read
badly, and they did not.

## What the follow-up needs

1. ~~The run results: `judge_fixtures`, then `judge_concept`, read by a
   person~~ — done, see "Run results" above.
2. A vocabulary entry in both language vocabularies, with a group decision:
   join module design, which keeps it out of Parsons, or a new group with its
   own constant.
3. Hosting: add it to `ExerciseSection::DesignComparison.hosted_concepts`.
   The drafts read well, so this condition is met.
4. The guidance line above as `AiService#proportionality_guidance`, under the
   one-line-per-group rule.
5. A prompt snapshot rebaseline and a Setup page snapshot rebaseline.
6. `JudgedGeneration::REJECT_SOLVE_MISMATCH_BELOW_PRINCIPAL` stays false. It is
   a separate decision for every design comparison concept, made after the
   disagreements are read.
