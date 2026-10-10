# app/services/claude_service.rb

## `#call`

When a caller passes `max_tokens`, thinking is turned off. A tight cap is shared between thinking and the reply, so with thinking on the model can spend the whole budget before it writes any reply text.

A refusal is returned as data in the result hash rather than raised here. That lets `call_and_log` write the usage row first, because a refused request still charges its input tokens.
