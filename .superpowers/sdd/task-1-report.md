# Task 1 Report — Prune unjudged provider extras for PR #201

## Scope
Implemented Task 1 only in the `pr-201-fixes` worktree:
- added judged-path-only extra-section pruning at the provider boundary
- kept the single-stage path unchanged
- added ingest-boundary and final judged-set regression coverage

## Files changed
- `app/services/problem_set_ingest.rb`
- `app/services/ai_service.rb`
- `spec/services/problem_set_ingest_spec.rb`
- `spec/services/ai_service_spec.rb`

## TDD log

### RED 1 — ingest boundary
Command:
```bash
bundle exec rspec spec/services/problem_set_ingest_spec.rb:143
```
Output:
```text
Failure/Error:
  def self.call(problem_set, language:, expected_keys:, code_review_source: nil, pitched_at: nil, eased_for: {}, fixed_concepts: {})
    ...
ArgumentError:
  unknown keyword: :prune_extras
```
Why this failure was expected:
- the new regression asked `ProblemSetIngest.call(..., prune_extras: true)` to support strict judged-path pruning
- the keyword did not exist yet, so the failure proved the test was exercising missing behavior rather than passing against existing code

### RED 2 — final judged-set behavior
Command:
```bash
bundle exec rspec spec/services/ai_service_spec.rb:5353
```
Output:
```text
Failure/Error: expect(judged.problem_set.keys).to contain_exactly("code_review", "pattern", "plan_review")

  expected collection contained:  ["code_review", "pattern", "plan_review"]
  actual collection contained:    ["ambiguity_hunt", "architecture", "code_review", "parsons_problem", "pattern", "plan_review", "pseudocode_to_code", "security_review"]
  the extra elements were:        ["ambiguity_hunt", "architecture", "parsons_problem", "pseudocode_to_code", "security_review"]
```
Why this failure was expected:
- `FakeService` returns every section kind, and the judged path was still preserving provider extras
- when the planned third was dropped, those extras remained in the persisted set and could still influence delivered-section identity
- the failure proved the regression was catching the bug Task 1 was meant to fix

### GREEN 1 — ingest boundary
Command:
```bash
bundle exec rspec spec/services/problem_set_ingest_spec.rb:143
```
Output:
```text
1 example, 0 failures
```

### GREEN 2 — final judged-set behavior
Command:
```bash
bundle exec rspec spec/services/ai_service_spec.rb:5353
```
Output:
```text
1 example, 0 failures
```

## Implementation summary
- Added `prune_extras:` to `ProblemSetIngest.call` / initializer.
- Pruned unrequested provider keys inside `warn_unrequested_sections!` only when:
  - `prune_extras: true` (judged draft path), or
  - `fixed_concepts.any?` (existing single-section retry strictness).
- Passed `prune_extras: true` only from `AiService#generate_judged_exercise` via `draft_exercise(..., prune_extras: true)`.
- Left `generate_exercise` on the original logging-only path.

## Focused verification
Command:
```bash
bundle exec rspec spec/services/problem_set_ingest_spec.rb spec/services/ai_service_spec.rb
```
Output:
```text
606 examples, 0 failures
```

## Full verification
Command:
```bash
bundle exec rspec
```
Output:
```text
2714 examples, 0 failures
```

## Self-review
- Confirmed the change stays at the provider boundary (`ProblemSetIngest`) rather than duplicating section filtering elsewhere.
- Confirmed the single-stage path remains byte-identical: only `generate_judged_exercise` opts into pruning.
- Confirmed the final regression asserts through `DailyExercise#active_section_keys`, the authority for delivered section identity.
- Requested code review. Reviewer found no blocking issues; only a minor interface-comment gap, which I fixed by documenting `prune_extras:` beside the ingest call contract.

## Commit
- Final commit: `8a27f32` — `Prune unjudged provider extras`

---

## Review-fix follow-up — Task 1 findings on commit `8a27f32`

### Root cause
- `AiService#generate_judged_exercise` threaded `prune_extras:` through `draft_exercise`, so the shared draft-building path no longer matched the single-stage generation path byte-for-byte.
- `ProblemSetIngest#call` still rejected missing expected keys before it warned and pruned extras, so strict mode could not apply its prune-first contract.

### Exact changes
- Removed `prune_extras:` from `AiService#draft_exercise` and restored its `ProblemSetIngest.call` invocation to the original shared shape.
- Moved strict pruning selection to `AiService#generate_judged_exercise`, which now re-ingests a `deep_dup` of `draft.problem_set` with `prune_extras: true` after the draft is built.
- Changed `ProblemSetIngest#call` to warn/prune before `reject_missing_sections!` only when `@prune_extras` is true; the non-strict path keeps the original missing-then-warn order.
- Added a judged-path regression proving the first ingest stays unchanged and the second ingest is where strict pruning is chosen.
- Added a strict-mode ingest regression proving extras are warned about before a missing planned section is rejected.

### RED evidence
Command:
```bash
bundle exec rspec spec/services/problem_set_ingest_spec.rb:155 spec/services/problem_set_ingest_spec.rb:169 spec/services/ai_service_spec.rb:5355 spec/services/ai_service_spec.rb:5369
```
Output:
```text
1) ProblemSetIngest.call warns about extras before rejecting a missing planned section in strict mode
   expected Rails.logger.warn(include("[unrequested_sections]")) once, received 0 times

2) AiService#generate_judged_exercise keeps draft ingestion unchanged and selects strict pruning only after the draft exists
   expected two draft ingest calls (plain first, strict second)
   got one draft ingest call with prune_extras: true
```
Why these failures were expected:
- the first regression asked strict mode to warn/prune before raising on a missing planned key, but the call still raised first
- the second regression asserted the shared draft path stays unchanged and strict pruning is selected only after the draft exists, but the code still threaded `prune_extras:` through `draft_exercise`

### GREEN evidence
Command:
```bash
bundle exec rspec spec/services/problem_set_ingest_spec.rb:155 spec/services/problem_set_ingest_spec.rb:169 spec/services/ai_service_spec.rb:5353 spec/services/ai_service_spec.rb:5368
```
Output:
```text
3 examples, 0 failures
```

### Verification
Focused suite:
```bash
bundle exec rspec spec/services/problem_set_ingest_spec.rb spec/services/ai_service_spec.rb
```
Output:
```text
608 examples, 0 failures
```

Full suite:
```bash
bundle exec rspec
```
Output:
```text
2716 examples, 0 failures
```

### Self-review
- Checked `AiService#retry_section`; it still uses the existing `fixed_concepts` strictness and was left unchanged.
- Checked `finish_generation`; using `deep_dup` at the judged seam preserves the draft for dropped-section logging while pruning only the delivered set.
- Kept the new coverage at the two reviewed seams only: judged orchestration and strict ingest ordering.

---

## Reviewer follow-up 2 — judged seam must not replay ingest

### Root cause
- My first follow-up fixed the reviewed seam location but chose the wrong mechanism: `generate_judged_exercise` re-ran `ProblemSetIngest.call` on the already-ingested draft to apply strict pruning.
- That second ingest replayed non-idempotent normalization, specifically `shuffle_parsons_blocks!`, so a judged `parsons_problem` could ship a different `display_order` than the draft had already established.

### Exact changes
- Replaced the judged seam's second `ProblemSetIngest.call` with `draft.problem_set.deep_dup.slice(*draft.kinds.map(&:key))`, so strict pruning still happens only after the draft is built but no ingest step is replayed.
- Kept `ProblemSetIngest#call`'s strict-mode ordering change from the prior follow-up: when strict pruning is selected there, extras are warned/pruned before missing expected keys are rejected; non-strict behavior is unchanged.
- Narrowed the judged-path seam regression to assert the draft ingestion call shape stays unchanged.
- Added a Parsons regression that fails if judged pruning replays ingest on an already-built set.

### RED evidence
Command:
```bash
bundle exec rspec spec/services/ai_service_spec.rb:5367
```
Output:
```text
1) AiService#generate_judged_exercise does not replay ingest on an already-built judged parsons_problem set
   expected: [[1, 3, 2, 0]]
        got: [[0, 2, 3, 1], [1, 3, 2, 0]]
```
Why this failure was expected:
- the new regression recorded every multi-section ingest of a judged Parsons day
- the first array element was the draft ingest's `display_order`, and the second was the replayed ingest after strict pruning
- the mismatch proved the judged seam was mutating already-normalized content instead of only pruning extras

### GREEN evidence
Command:
```bash
bundle exec rspec spec/services/ai_service_spec.rb:5353 spec/services/ai_service_spec.rb:5367 spec/services/ai_service_spec.rb:5387
```
Output:
```text
3 examples, 0 failures
```

### Verification
Focused suite:
```bash
bundle exec rspec spec/services/problem_set_ingest_spec.rb spec/services/ai_service_spec.rb
```
Output:
```text
609 examples, 0 failures
```

Full suite:
```bash
bundle exec rspec
```
Output:
```text
2717 examples, 0 failures
```

### Self-review
- Re-checked the two original review findings after removing the second ingest: `draft_exercise` no longer accepts or threads `prune_extras:`, and strict pruning still happens only at the judged orchestration seam after the draft exists.
- Re-checked the strict ingest regression; `ProblemSetIngest#call` still warns/prunes before rejecting a missing planned key when `prune_extras: true` and keeps the original order when false.
- Kept scope to the seam bug only; no other ingest behavior changed.

### Verification note
- The earlier verification blocks above are historical outputs from the original implementation and the first follow-up revision.
- For the final branch state on commit `5ecb483`, the authoritative verification is the latest "Reviewer follow-up 2" section: `609 examples, 0 failures` for the focused suite and `2717 examples, 0 failures` for the full suite.
