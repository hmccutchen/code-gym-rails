# app/models/user_text.rb

## `UserText`

Invisible characters are still text to a model, so the module strips them from what an engineer typed before it reaches a prompt.

## `BIDI`

Every character in this range reorders what a browser draws without changing what a model reads (the Trojan Source technique), so all of them are stripped.

## `MAX_ANSWER_LENGTH`

The cap applies per section, so one long answer cannot dominate every later prompt that quotes it.

## `.clean`

Normalizes before truncating, so removed characters cannot use up the cap.

## `.labelled`

A blank value renders inline after the label, so a skipped answer stays one short line.

## `.tag_history`

Earlier user turns are fenced and capped at the caller's limit. Assistant
turns pass through `.defanged` without a wrapper or length cap, so a stored
reply cannot impersonate engineer text on the next call. `DuckPrompt` and
`FollowUpPrompt` share this boundary; #822 extends the duck-only #819 fix to
follow-ups without another tag-matching rule.

Roles and extra fields are preserved, and Hash keys are symbolized as before.
Unknown roles and non-Hash entries pass through. Ordinary assistant prose,
including indentation and long replies, stays intact. Gemini's separate
`flatten_history` role-forgery limitation remains outside this boundary.

## `.defanged`

Normalizes text and neutralizes engineer tags without adding a wrapper that
would identify the text as the engineer's. `.tagged` uses the same rule with
its existing length cap. Callers that omit `limit:` keep the full text.
