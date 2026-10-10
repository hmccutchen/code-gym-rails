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

Earlier user turns are fenced too. Assistant turns pass through unchanged, even though the duck's assistant turns come from the client.
