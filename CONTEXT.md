# Context

## Why this exists

Junior and newer engineers on the team ramp faster with deliberate, repeated
practice — but there's no natural forcing function for that in day-to-day
work, where tickets favor whatever's urgent over whatever builds skill.
Code Gym is that forcing function: a short, personalized set of exercises
every weekday morning, tuned to each person's actual performance history
rather than a generic curriculum.

## Who it's for

Internal team tool. Built for this engineering team specifically — not a
product aimed at other teams or external users. Every teammate logs in with
their own account and their own AI provider key; there's no multi-tenant or
customer-facing surface to design around.

## What "good" looks like

- A junior engineer's weak spots (a concept they keep rating "hard," a
  pattern they avoid) show up again in later problem sets until they stick.
- The daily set is short enough to actually finish before other work crowds
  it out.
- Feedback and difficulty ratings feed back into tomorrow's generation, so
  the loop tightens over time instead of staying generic.
- Nobody needs to remember to run it — it's already waiting at 8am, and
  falling behind on a day doesn't break the next one.

## Non-goals

- Not trying to replace structured onboarding docs, pairing, or code review —
  it's a supplement for hands-on reps, not a substitute for mentorship.
- Not built for scale beyond one team; no billing, multi-org, or admin
  surface is planned.
- Not a general coding-practice product — problem generation is intentionally
  scoped to this team's stack and conventions (see `CLAUDE.md`), not a broad
  language/topic catalog.

## Relationship to CLAUDE.md

`CLAUDE.md` is the engineering reference — stack, architecture, models, key
technical decisions. This file is the "why" behind it: who it's for and what
problem it's solving. Update this file when the product intent changes;
update `CLAUDE.md` when the implementation does.
