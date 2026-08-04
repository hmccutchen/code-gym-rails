# Test-analysis content folded into code_review — design

## Problem

Engineers should occasionally practice spotting issues in test code itself
(over-mocking, testing implementation details instead of behavior) — not
just application-code bugs. This is deliberately narrow: analyzing/critiquing
a given test file, not writing tests from scratch, matching how Parsons
problems are scoped to reordering rather than free-form implementation.

## Investigation findings

- `code_review` is a fixed top-level key in `exercise_schema_for`
  (`app/services/ai_service.rb:489-496`), outside the `third_section` case
  statement that varies by `third:` — it's present in every exercise set
  regardless of the day's third section. No branch to add.
- `ExerciseSection::CodeReview` (`app/models/exercise_section/code_review.rb`)
  is an empty subclass, matching every other kind's architecture — no logic
  lives there to touch.
- The only prompt instruction specific to code_review's content is one line:
  `app/services/ai_service.rb:633` — *"The code_review snippet must be
  realistic #{label} code — not toy examples."*
- Grading (`build_review_prompt`) evaluates code_review generically against
  its `question`/`concept`/`snippet`/answer — no kind-specific branch to add.

This confirms the feature is additive: a vocabulary change plus one prompt
instruction, no schema/model/grading changes.

## Design

**1. Vocabulary additions.** Add two concepts to both `RAILS_CONCEPTS` and
`JS_CONCEPTS` (`app/services/ai_service.rb:33-46`):

- `over_mocking` — mocking/stubbing so much of the system under test that
  the test no longer verifies real behavior.
- `testing_implementation_not_behavior` — asserting on internal
  implementation details (private state, call counts, internal structure)
  instead of observable outcomes, so the test breaks on safe refactors.

These were chosen over two broader candidates (`brittle_test_smells`,
`missing_edge_case_coverage`) because they're each one specific, spottable
issue with a clear fix — the same depth bar applied when trimming security
concepts to only those with real depth (see `RAILS_CONCEPTS`'s comment
block). `RAILS_CONCEPTS` grows from 18 to 20 entries; `JS_CONCEPTS` from 20
to 22.

This is the same pattern `TYPESCRIPT_FLAVORED_CONCEPTS` uses to join
`JS_CONCEPTS` — fold into the existing vocabulary rather than introducing a
new one, so concept history stays aggregatable under the existing bucket
(`ConceptBucket` buckets by language, unaffected by this).

**2. Prompt instruction.** Extend the existing code_review instruction line
(`app/services/ai_service.rb:633`) to allow the snippet to occasionally be a
test file instead of application code:

```
- The code_review snippet must be realistic #{label} code — not toy examples. Roughly 1 in 4 sessions, make it an RSpec-style (Rails) or Jest/Vitest-style (JS) test file exhibiting a real test smell instead — same question shape ("what's the issue here, and how would you fix it").
```

This keeps code_review's schema, question shape, and grading identical —
only the pool of what the snippet can depict grows. The `~1 in 4` framing
matches the existing legacy-GraphQL scenario's style of giving the model a
concrete rough ratio, but more frequent, since this is core content variety
rather than rare scenario dressing.

**3. No other changes.** No new `ExerciseSection` subclass, no new rotation
weight, no new grading branch, no new review-prompt branch, no schema keys
added/removed. `pattern`, `challenge`, `architecture`, `security_review`,
`parsons_problem`, `DailyPlan`'s rotation logic, and the mastery-tier system
are all untouched.

**4. Tests.** In `spec/services/ai_service_spec.rb`:
- Bump the two exact-size assertions (`RAILS_CONCEPTS.size` from 18→20,
  `JS_CONCEPTS.size` from 20→22, currently at lines 190 and 206) and add
  `include("over_mocking", "testing_implementation_not_behavior")`
  assertions for both lists.
- Add one new test under `describe "#build_exercise_prompt"` asserting the
  prompt includes the test-file instruction text, following the existing
  convention for prompt-instruction specs in this file (e.g. the
  `"never the full answer"` teaching_note check).

**5. Coverage via FakeService/system specs.** No new fixtures needed.
`FakeService` returns canned code_review content regardless of the day's
concept, so existing system specs continue to exercise the code_review path
unchanged — this content doesn't need a dedicated system-test fixture, only
the generation prompt path needs to know about it (covered by the service
spec above).

## Out of scope

- No changes to `pattern`, `challenge`, `architecture`, `security_review`,
  or `parsons_problem`.
- No changes to `DailyPlan`'s rotation logic or the mastery-tier system.
- No migration — this is prompt/vocabulary only.
