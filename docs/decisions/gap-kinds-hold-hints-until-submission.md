# Gap kinds hold their hints until submission

Decided 2026-11-03 (#564, #678).

In a plan review the engineer finds what is wrong with a plan, and in an ambiguity hunt what a request leaves unstated. The answer key lists those gaps, and it is hidden until review. Two things on the answer form could name a gap before the engineer finds it.

## Glossary tooltips

Some glossary definitions state a consequence: a replica "can lag behind the primary", a soft delete means "every query has to filter it out". On a plan that reads from a replica, that tooltip is the flaw. So on these two kinds, no prose field shows tooltips before submission.

- Each kind answers `.glossary_shown_before_submission?`. It is false for `PlanReview` and `AmbiguityHunt`.
- Every prose field on the answer form goes through `GlossaryHelper#section_glossary_wrap`, which reads it. `spec/conventions/app_views_spec.rb` fails on a raw `glossary_wrap` in a section view.
- After submission, the tooltips come back.
- The definitions stay as they are. #563 decided that a definition stating its consequence is what a glossary is for, and rewriting about 290 entries to avoid consequences would make every other page worse.

`pseudocode_to_code` keeps its tooltips. Its hidden key lists requirements the problem statement states outright, so a definition can only draw attention to text the engineer already sees. `code_review` and `security_review` hide their answer in code, which is never wrapped. Every kind with an answer key has its value recorded in `spec/models/exercise_section_spec.rb`, so a new keyed kind fails that spec until someone decides.

## The concept

For these two kinds, the concept is the category of the gap: `scope_creep`, `silent_behavior_change`, `unspecified_edge_cases`, `missing_success_criteria`. The concept reference card names it, explains it and gives its tagline, which tells the engineer what kind of gap to look for. `SectionKindGuide` is already held to naming no kind of gap for the same reason.

Both kinds return false from `.concept_shown_before_submission?`, the hook a `bug_hunt` section uses (`docs/decisions/bug-hunt.md`). Before submission, the section shows no concept reference and no featured marker, and the dashboard leaves the featured callout off when it features that concept.

The missing callout is itself a signal. Learn always shows the week's featured concept, so its absence on the dashboard tells a user who checks Learn what today's concept is. With 4 or 5 concepts per kind, that narrows a lot. #680 holds that open question.
