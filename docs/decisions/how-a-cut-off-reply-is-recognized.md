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
already were. The thinking partner's `duck_thread` profile in
`AiService::CALL_PROFILES` sets `allow_truncated: true`, so a
partial reply is shown with an ellipsis, and an empty one still fails
`text_or_raise`. Gemini and OpenAI both accept only `completed` or
`incomplete`, through `AiService::FINISHED_STATUSES`. Any other status is an
error, raised after usage recording even when partial prose is allowed,
because a failed interaction can still bill tokens (#245). That covers
`failed` and `cancelled`, and also `queued`, `in_progress` and
`requires_action`, which this app's synchronous `store: false` calls are not
expected to receive. The status is logged so a recurring failure can be told
apart. OpenAI rejects a reply with no status. Gemini still accepts one, as it
did before #245, because nothing yet shows the API always sends a status.
OpenAI's `incomplete` status is truncation unless the reason is
`content_filter`, which is a refusal, as is a refusal content block.
An authentication error (401 or 403) from any provider gets fixed guidance
naming the company and logs only the HTTP status, through
`AiService#raise_if_key_rejected`, because the provider's error body can
echo the key or its fragments. Gemini reports an invalid key as a 400 whose
details carry `API_KEY_INVALID`, so `GeminiService` reads that body for the
reason, never logs it, and raises the same `AuthenticationError`.
