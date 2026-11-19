# `DuckPrompt`

The duck's prompt, moved out of `AiService` (#431). `AiService#duck_response` still makes the call, checks the reply and marks a cut-off one. It is one of the two conversational calls, so it returns `history:` beside `system:` and `prompt:`. The settings, system-prompt caching included, stay in `CallProfiles::BY_PURPOSE`.

## `.generate`

It takes one section's data and renders it only through `SectionContext.render`, so no answer key reaches the duck before submission, and it never sees the response, the review or another section. The engineer's new message and their earlier turns are fenced (`UserText.tagged`, `UserText.tag_history`). Earlier turns come from the stored thread.

Earlier duck replies keep their assistant role. `UserText.tag_history` passes
them through `UserText.defanged` without an engineer-text wrapper or an answer-length cap.
This neutralizes forged engineer tags in provider text before the next call,
so a duck reply cannot mark its own words as the engineer's.

## `EXPLAIN_REQUEST`

Owned by the server so its wording sits beside the prompt it is tuned against.
It counts against the turn cap like any other message.

## `KINDS`, `CONDUCT` and `SYSTEM`

`SYSTEM` is `KINDS` and `CONDUCT` joined the way the single heredoc used to
be, so its bytes are unchanged and `duck_prompt_characterization_spec` and
the `duck__*` snapshots hold it. The split is only there so `NARROWING` can
sit right after the two kinds.

## `labelled:` and `narrow:`

Both default to false, and with both false `.generate` returns today's
prompt. `labelled: true` adds `POINT_LABEL` after `CONDUCT`, asking each
guiding question to end on a `Point:` line. The duck never sees its earlier
labels, because `DuckThread#turns_for` leaves them out, so the line asks for
the same wording each time rather than telling it to copy a label.
`narrow: true` adds `NARROWING`, the owner's wording, after `KINDS`. The
controller passes `narrow:` only together with `labelled: true`. Either
line changes the system prompt, so a turn that flips one misses the
provider's cached system prompt once.
