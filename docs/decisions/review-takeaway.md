# Review takeaway and progressive disclosure

The Today and History review can show one short, verbatim essential miss
above a closed **Full review**. The grade, takeaway, and follow-up stay
visible as the learner opens the details. The original entry stays in its
list inside the full review. History keeps its existing outer session
disclosure. Skipped sections and sections without a reliable excerpt keep
their existing rendering.

`ReviewTakeaway` checks the rating against one distinct essential-gap
position in the original graded prose. It requires an exact, unique match
in the displayed list before accepting the source text. The passage must
fit one or two complete sentences and a 400-character backstop. The extra
room lets graders name relevant identifiers and keep conditions and
consequences in plain language. Ineligible prose stays in the full review.
The existing glossary wraps the takeaway on display.

`REVIEW_TAKEAWAY` is off by default and only enabled by an exact `1`.
The web renderer reads existing review data. Prompts, provider call
counts, grading, mastery, persistence, and review email behavior stay as
they are.

## Local verification

Use a local development database and a fake-provider account. Give the
account a submitted exercise with an answered non-fixed section and a
stored review using the current rubric stamp, a `developing` or
`beginner` rating, and one well-formed essential position. For example,
store `essential_gaps: [0]` with the matching Missed entry “The loop runs
one extra query per order. A large order list can therefore trigger many
round trips.” Include a skipped or unstamped review to compare.

Start the development server with `env -u REVIEW_TAKEAWAY bin/dev`.
Inspect Today and History. Stop that server and restart with
`REVIEW_TAKEAWAY=1 bin/dev`. Confirm the takeaway stays visible while
Full review opens and closes, the glossary works, and the follow-up stays
available. Repeat at about 360 px with keyboard and touch. Restart with
the flag unset to confirm the original view returns. To exercise both
states with test fixtures and fake providers, run:

```bash
bundle exec rspec spec/requests/dashboard_spec.rb spec/requests/history_spec.rb spec/requests/existing_account_pages_spec.rb
bundle exec rspec spec/system/review_takeaway_spec.rb
```

## Owner-controlled trial

Use existing authorized review data or fixtures in the environment the owner
chooses. The owner controls activation and rollback. Record one row for
each of the first ten eligible response sections, counting a section once
across Today and History. Record the local identifier, kind, page, viewport,
pass or fail for each question, and a brief explanation of any failure.
Keep answer and review text out of logs. Record sparse eligibility separately.

1. With Full review closed, can the learner restate the takeaway after one
   reading?
2. Does it explain the relevant lesson and why it matters when the evidence
   supports a reason?
3. Can the learner follow it without unexplained assumptions or context?
4. Do existing glossary tooltips clarify the needed terms without clutter?
5. After opening Full review, does the takeaway accurately reflect the
   answer and both the original grading evidence and displayed feedback?
6. Is Full review easy to find and open, with the takeaway and follow-up
   still accessible?
7. At about 360 px, is the review easier to scan than with the switch off?

An accurate but incomprehensible takeaway fails. Count each unclear or
unhelpful result once when it fails standalone understanding or
instructional value. More than two among the first ten triggers
reconsideration of the selection policy before expanding the trial. One
materially misleading takeaway triggers immediate owner-controlled
switch-off. Check that the existing review is restored. These observations
assess readability, fidelity, and usability. They do not measure retention
or learning outcomes.
