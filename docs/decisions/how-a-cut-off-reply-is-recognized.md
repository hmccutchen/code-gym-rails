# How a cut-off reply is recognized

each provider reports truncation as
data and `AiService#call_and_log` decides it is fatal, after writing the
usage row. Claude reads `stop_reason == "max_tokens"`. Gemini reads the
interaction's `status == "incomplete"`, which the Interactions API defines
as completed with incomplete results, hitting max_tokens being one example;
token counts are not consulted, because a live call capped at 60 stopped at
56 output tokens with that status and the old "output reached the cap" rule
missed it (#243). Since that status does not say why the reply stopped, the
error says the provider "did not finish its reply" rather than naming a
limit. Uncapped Gemini calls are flagged too, as uncapped Claude calls
already were. The thinking partner passes `allow_truncated: true`, so a
partial reply is shown with an ellipsis, and an empty one still fails
`text_or_raise`. A `failed` or `cancelled` Gemini interaction is not handled
here. OpenAI accepts only `completed` or `incomplete` responses; any other
status is an error, raised after usage recording even when partial prose
is allowed. Its `incomplete` status is truncation unless the reason is
`content_filter`, which is a refusal, as is a refusal content block.
An authentication error (401 or 403) from any provider gets fixed guidance
naming the company and logs only the HTTP status, through
`AiService#raise_if_key_rejected`, because the provider's error body can
echo the key or its fragments. Gemini reports an invalid key as a 400 whose
details carry `API_KEY_INVALID`, so `GeminiService` reads that body for the
reason, never logs it, and raises the same `AuthenticationError`.
