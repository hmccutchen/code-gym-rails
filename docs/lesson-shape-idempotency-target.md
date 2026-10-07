# Lesson shape target: idempotency

A hand-written example of the lesson shape the pilot asks for. Nothing in the
app reads this file. `script/compare_concept_lessons.rb` copies the text
between the markers into its comparison, beside the current and candidate
lessons for idempotency, so a reader can hold both against it.

<!-- target:start -->
IDEMPOTENCY

In one sentence: an action is idempotent if doing it once and doing it
ten times leave things in the same state.

Everyday version: the call button on an elevator. Press it five times
and one elevator comes. Compare an "add one more scoop" button at an ice
cream counter: five presses, five scoops. Where the comparison stops:
the elevator button has no side effects. Real systems also send emails
and write rows, and those are what usually get repeated.

Common mix-up: idempotent does not mean the code runs once. It can run
many times. What matters is that the effect doesn't pile up.

When you run into it: a double tap on a slow connection. A job queue
that retries after a timeout. A webhook delivered twice. A request that
worked, but the reply got lost, so the caller tries again.

Four habits, each with its catch:
- Send the end state, not the change. "Set the amount due to $40," not
  "subtract $10." Catch: an old message that arrives late can overwrite
  a newer one.
- Let the database refuse duplicates with a unique constraint. Catch: it
  stops duplicate rows, not duplicate emails.
- Check and update in one step. Catch: if the check and the update are
  separate, two requests can both pass the check.
- Give each action an ID and reuse it on a retry. "Pay invoice 1042,
  reference R-77." Catch: a fresh ID on every retry defeats the point.

Question to carry: what in this feature could happen twice, and what
stops each one?

Quick test: run the action twice at the same moment. Stop it halfway and
retry. Reuse an ID with different details and see what happens.
<!-- target:end -->
