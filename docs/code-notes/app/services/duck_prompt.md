# `DuckPrompt`

The duck's prompt, moved out of `AiService` (#431). `AiService#duck_response` still makes the call, checks the reply and marks a cut-off one. It is one of the two conversational calls, so it returns `history:` beside `system:` and `prompt:`. The settings, system-prompt caching included, stay in `CALL_PROFILES`.

## `.generate`

It takes one section's data and renders it only through `SectionContext.render`, so no answer key reaches the duck before submission, and it never sees the response, the review or another section. The engineer's new message and their earlier turns are fenced (`UserText.tagged`, `UserText.tag_history`), since the page sends the thread back and a forged turn is one request away.

## `EXPLAIN_REQUEST`

Owned by the server so its wording sits beside the prompt it is tuned against.
It counts against the turn cap like any other message.
