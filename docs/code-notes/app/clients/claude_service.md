# app/clients/claude_service.rb

## `#request_body`

When the request carries `max_tokens`, thinking is turned off. A tight cap is shared between thinking and the reply, so with thinking on the model can spend the whole budget before it writes any reply text.

## `#read_result`

A refusal is returned as data in the result hash rather than raised here. That lets `call_and_log` write the usage row first, because a refused request still charges its input tokens.
