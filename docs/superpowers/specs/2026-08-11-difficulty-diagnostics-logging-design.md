# Difficulty diagnostics logging

## Why

Nearly all difficulty adaptation in this app is advisory, not enforced.
`build_exercise_prompt` tells the model things like "if they've been rating
exercises too easy, increase difficulty" and "reduced-tier concepts get
simpler framing and more scaffolding" — but nothing verifies the returned
problem set actually reflects those instructions. This is unlike the parts of
the app that *are* enforced (Parsons grading computed in Ruby with the
model's rating overwritten, concept normalization forcing off-vocabulary tags
to `"other"`, deterministic retention scheduling, and the one existing
delivery check, `AiService#log_retention`).

The user's subjective impression is that problems feel the same difficulty
regardless of ratings, and that `feedback_text` notes may not influence
anything. Before changing generation logic on that impression alone, this
makes the gap between "what was requested" and "what was delivered"
measurable, so a future fix (or a decision not to fix anything) can be judged
against real data instead of another guess.

This is **instrumentation only**. No prompt wording, schema, generation
logic, or mastery-tier behavior changes. Purely observational.

## What gets logged

Two JSON-lines events, written to `Rails.logger` (STDOUT in production —
this app's `config/environments/production.rb` already logs to STDOUT
specifically because Railway's filesystem is ephemeral; a dedicated log file
would be lost on every deploy/restart, so that option is out), each prefixed
`[difficulty_diagnostics]` the same way the existing `AiService#log_retention`
prefixes its lines with `[retention]`. Correlated by `user_id` + `date` — no
new identifier needed, matching how `log_retention` already correlates.

`DailyResponse.date` is set independently at save time
(`find_or_initialize_by(daily_exercise:, date: Date.current)`), so a set
generated late at night and first saved after midnight could otherwise get a
review event dated the day *after* its generation event. The review event
logs `response.daily_exercise.date`, not `response.date`, specifically to
avoid this — the exercise's date is always the generation event's date.

Generation-time logging runs on the `worker` Solid Queue service; review-time
logging runs on the `web` service — they're two different Railway log
streams, so reading a week of correlated data means exporting/reading both,
not just one.

**Extracting these logs from production.** `config/environments/production.rb`
sets `config.log_tags = [:request_id]`, which prefixes every emitted line
with a request-id tag — so `[difficulty_diagnostics]` is not actually at the
start of the line in production (it only appears at the start in test, which
sets no log tags). Generation runs on the worker outside a request (so it
likely carries no tag prefix there) while review runs on web inside a request
(so it does) — the two correlated events won't even share the same prefix
shape. Don't grep/strip assuming the tag starts the line; match on the
`[difficulty_diagnostics]` marker itself and strip everything up through it:

```sh
grep '\[difficulty_diagnostics\]' production.log \
  | sed 's/.*\[difficulty_diagnostics\] //' \
  | jq
```

### Generation event

Logged from a new private `AiService#log_difficulty_diagnostics(user,
language, plan, problem_set)`, called from `#generate_exercise` right beside
the existing `log_retention` call. Because cron generation, on-demand
generation, and `RegenerateExerciseJob` all call `AiService#generate_exercise`,
this one hook point covers all three with no other call sites touched.

`RegenerateExerciseJob` calls this same hook, so a single `user_id` + `date`
can have more than one `"generation"` event if the user regenerated that day
— a reader should take the *last* one for a given day, since earlier ones
describe a set the user never actually saw.

```jsonc
{
  "event": "generation",
  "user_id": 42,
  "date": "2026-08-11",
  "language": "javascript",
  "requested": {
    "skill_level": "mid",
    "reinforcement": [{ "concept": "hooks_dependencies", "tier": "reduced" }],
    "due_checks": ["closures"],
    "established": ["event_loop_blocking"],
    "recent_performance": [ /* exactly what user.recent_performance(limit: 10)
      already returns: date, feedback, concepts, self_ratings, ai_ratings,
      sections_answered, scenarios — this is the same data
      build_exercise_prompt renders into history_text, not a new query */ ]
  },
  "delivered": {
    "code_review": { /* full normalized problem_set["code_review"] hash —
      concept, title, scenario/snippet, question, etc. — whatever that
      section kind carries */ },
    "pattern": { /* ... */ },
    "architecture": { /* ... whichever third section was chosen ... */ }
  }
}
```

`delivered` logs each section's full hash from the already-normalized
`problem_set` (after `normalize_concepts`/`normalize_answer_scaffolds!`/
`normalize_diagrams!`/`shuffle_parsons_blocks!` have all run — the same
object persisted to `DailyExercise`), rather than hand-picking fields per
section kind. `code_review`, `pattern`, `architecture`, `security_review`,
and `parsons_problem` all shape their hash differently; logging the whole
thing is simpler than a per-kind field list and automatically covers any
future section kind without editing this method.

### Review event

Logged from `ResponsesController#review`, once per call, for whichever
sections that call successfully reviewed (`successes` — review can complete
in more than one batch if earlier attempts partially failed, so this may fire
more than once for one day's response).

```jsonc
{
  "event": "review",
  "user_id": 42,
  "date": "2026-08-11",
  "sections": {
    "code_review": { "ai_rating": "solid", "self_rating": "right_level" }
  }
}
```

`ai_rating` comes from `DailyResponse#ai_rating_for(section)`, `self_rating`
from `DailyResponse#self_rating_for(section)` — both already computed;
nothing new to derive.

## Why JSON instead of the existing logfmt style

`[retention]`'s key=value line works because its payload is a handful of
concept names. This payload includes full section text (scenario/snippet/
question) and a 10-entry performance history array — unreadable as escaped
logfmt key=value pairs, natural as a JSON blob.

## Not building

- **No persistence or query layer.** This is meant to be read by a human over
  roughly a week, correlated by two plain fields (`user_id`, `date`). Plain
  STDOUT JSON lines, greppable by the `[difficulty_diagnostics]` tag and
  parseable with `jq` once pulled from Railway's log viewer, are enough. If
  it turns out a week of entries is too much to read by eye, that's a signal
  to revisit — not a reason to build a table now.
- **No migration.** Nothing here is persisted in the database.
- **No change to what any generation call actually asks for or receives.**

**Accepted tradeoff.** The generation payload includes user-authored
`feedback_text` (via `recent_performance`) and full problem-set content,
going to the log stream. This is accepted given this app's internal-team-only
scope (see CONTEXT.md) and this instrumentation's short intended lifespan —
it should be removed once the difficulty question is settled, not left
indefinitely.

**Known follow-up (not addressed here).** Very large payloads could get
truncated by Railway's log pipeline; this needs an empirical check against a
real production generation rather than a speculative code change to shrink
the payload shape.

## Testing

Request/service specs asserting `Rails.logger` receives an `info` call whose
message, once the `[difficulty_diagnostics] ` prefix is stripped, parses as
JSON containing the expected top-level keys (`event`, `user_id`, `date`, and
either `requested`/`delivered` or `sections`) — confirming the wiring holds
and neither event is silently dropped, not asserting exhaustive content.

## Comment convention

Each new method carries a comment stating why this instrumentation exists
and what question it answers (per `[retention]`'s existing comment style),
so a future reader can tell at a glance whether it's still needed or safe to
remove once the difficulty question is settled.
