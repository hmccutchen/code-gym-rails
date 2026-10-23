# Grading rubric

`ReviewPrompt::RATING_RUBRIC` is the one definition of
the four review ratings, stated once in the review's shared day context.
A rating describes how the answer meets the level its section was pitched
at, so `solid` means the same at junior and senior: beginner missed the
main point, developing found it but missed or misexplained an essential
piece, solid has no essential misses, and strong is solid plus something
the question did not ask for, such as a tradeoff or a consequence. A gap is
essential when, left as written, the code or decision would behave wrongly
or a stated requirement would go unmet. Each kind's grading note names its
own main point and essential pieces and never restates the levels; a spec
holds every grader-rated kind to that. Parsons is the exception: its
`fixed_rating` hook computes the rating in Ruby from how many blocks are
out of place and replaces the grader's, except when the stored section has
no blocks to compute from. The hook is the only statement of that rule;
shared grading code calls it for every kind.

**The grader is told the pitched level.** `ReviewPrompt.section_prompt`
states the section's `pitched_at` rung and its
`KindDifficulty::LEVEL_DEFINITIONS` sentence. `AiService#review_rung` falls back to
`KindDifficulty#rung_for` (target included) for an unstamped section.
`eased` is never passed; the rubric instead says a problem simpler than
its level's description is graded on what it actually asks. The day context no
longer calls the engineer "junior/mid", which would contradict a senior
pitch.

**The rubric is checked, never enforced.** The grader also returns
`essential_gaps`, the positions in "missed" it counts as essential.
`RubricCheck` reads them against the rating (solid and strong list none,
beginner and developing at least one) and `[rubric_check]` logs counts and
`agrees=true|false|unknown` for every section whose rating the grader
chose, never review text; a computed rating is not checked.
Positions it cannot read are dropped rather than stored, and are counted
against "missed" as the grader returned it, blanks included. Nothing
rewrites a rating from this; the log is how the rubric's adherence is
measured. The check runs before the prose judge, and when the judge
rewrites a review the positions move into `graded_prose`, beside the list
they number.

**`ReviewedSectionResults::RUBRIC_VERSION`** is stamped into every review the prompt
grades (`ai_review[section]["rubric"]`, server-owned). It lives with
`ReviewedSectionResults`, the rule for which reviewed sections count as
evidence, and `AiService` writes it. A review without it
was graded with no rubric, so its rating answers a different question; an
evidence reader that compares ratings to a bar reads only stamped reviews.
A stamp rather than a cutoff date, because grading knows which prompt it
ran and a date misfiles a review retried across a deploy. The competency
gate and `LevelSuggestion` read it; `ConceptMastery` and `RungLedger` read
all history on purpose. Going forward, a concept's
first post-rubric review is compared with a pre-rubric `last_rating`, so
that one comparison can read as improving or stagnant because the scale
moved rather than the engineer.

**Calibration.** `script/compare_models.rb review_calibration` grades the
complete, partial and missed answers in `spec/fixtures/review_calibration/`
through the production review route and reports whether each fixture's
three ratings fall in rank order, how many complete answers reach solid,
and the run's cost including cache writes. At introduction it ran 5/5 in
order and 15/15 at the expected rating on Claude, about $0.21. Re-run on
2026-10-09 with the design comparison fixture included: **6/6 in order,
20/20 at the expected rating, 20/20 agreeing with the essential gaps it
listed, and 6/6 complete answers at solid or better**, on
`claude-sonnet-5-5` for $0.2613 (10,713 in, 24,426 cache write, 0 cache
read, 17,878 out). The fixtures are deliberately
clear-cut: they show the levels separate, not where a borderline answer
lands. That includes the design comparison fixture's two extra answers,
which had not been run before: a matching pick with a vague reason graded
`beginner` and the other pick with a sound reason graded `developing`,
both as the kind's grading note asks.
