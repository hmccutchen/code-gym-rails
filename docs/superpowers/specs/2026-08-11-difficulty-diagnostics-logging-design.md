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

### Generation event

Logged from a new private `AiService#log_difficulty_diagnostics(user,
language, plan, problem_set)`, called from `#generate_exercise` right beside
the existing `log_retention` call. Because cron generation, on-demand
generation, and `RegenerateExerciseJob` all call `AiService#generate_exercise`,
this one hook point covers all three with no other call sites touched.

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
