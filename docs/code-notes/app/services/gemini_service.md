# app/services/gemini_service.rb

## `MODEL_FOR_PURPOSE`

Generation and its retry map to `DEFAULT_ROUTE` explicitly, even though an unlisted purpose would fall back to it anyway. Listing them lets the route coverage spec pin both usage labels.

## `MINIMAL_THINKING_LEVEL`

On Gemini, thinking shares the output cap, and Gemini 3 Flash cannot turn thinking off. `minimal` is the lowest level it accepts, so a capped call sends it to leave the most room in the cap for the reply.

## `#retry_delay_from`

Gemini states the wait two ways. `RetryInfo.retryDelay` in the error body is a duration string such as `"39s"`, while the `retry-after` header is whole seconds. The method reads the body's duration first, rounds it up, and falls back to the header.
