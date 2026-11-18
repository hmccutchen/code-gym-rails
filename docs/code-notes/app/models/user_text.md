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

Earlier user turns are fenced too. This helper leaves assistant turns unchanged;
`DuckPrompt` separately neutralizes its stored assistant turns with `.defanged`.
`FollowUpPrompt` still passes assistant turns through unchanged, leaving its
pre-existing assistant-tag forgery gap outside the duck-only #819 scope.
The shared tag-matching rule remains in `.defanged`; `.tag_history` is not
broadened by that fix.

## `.defanged`

Normalizes text and neutralizes engineer tags without adding a wrapper that
would identify the text as the engineer's. `.tagged` uses the same rule with
its existing length cap. Callers that omit `limit:` keep the full text.
