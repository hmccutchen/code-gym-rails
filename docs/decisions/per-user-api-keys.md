# Per-user API keys

Each user provides their own Anthropic, Gemini or OpenAI key, and can keep one for each. Zero shared cost. A pasted key's prefix (`sk-ant-`, `AIza`/`AQ.`, or `sk-proj-`/`sk-svcacct-`/legacy `sk-`) decides which provider it is saved under; the OpenAI pattern requires alphanumerics straight after a bare `sk-`, so it can never claim an Anthropic key whatever order the patterns are tried in. Pasting a key replaces only that provider's key and selects it (`User#store_api_key`); Setup's "Provider in use" radios switch between saved keys without re-entering one, and list only providers with a saved key (`User#stored_providers`). `user.provider` names the one in use, `User#api_key` reads its key, and `AiService.for(user)` dispatches on it, so nothing downstream knows there is more than one. The keys are stored together in `users.api_keys`, a JSON map serialized and then encrypted with `encrypts :api_keys` (ActiveRecord Encryption); no keys stores as NULL, so `where.not(api_keys: nil)` finds the accounts that can call a provider. A map rather than a column per provider keeps adding a provider a matter of adding a class. `users.api_key`, the single-key column it replaced, was ignored for one release while the old code served through the pre-deploy migration, and `RemoveApiKeyFromUsers` dropped it once a production check found no key held only there. Each reviewed response records the provider that wrote it in `daily_responses.review_provider`, so History and the dashboard keep naming it after a switch; a part-reviewed day finished on another provider names the last one. `ResponseReview` sets it on every review, and the preview seed sets it on its seeded one. `AddReviewProviderToDailyResponses` backfilled earlier reviews, storing `unknown` (labelled "AI") for a user whose `api_usages.model` rows name another provider; models were recorded only from 2026-10-01, so a switch before that left no trace, and those reviews keep the current provider's name. A response with none reads as the current provider (`DailyResponse#review_provider_key`, named on the page by `ReviewHelper#review_provider_label`); a production check on 2026-10-14 found no reviewed response without one, so the provider switch no longer labels unlabelled reviews first. Setup says nothing about how providers differ: the prose judge runs on Claude only, and it, structured output and caching change the wording of a review, cost and reliability rather than anything an engineer does differently. The `ACTIVE_RECORD_ENCRYPTION_*` env vars are wired in via `config/initializers/active_record_encryption.rb` (Rails does not read them from ENV on its own); development derives throwaway keys from `secret_key_base` automatically.

## A key is checked when it is saved

Before this, Setup accepted any key whose prefix matched a provider, and a
mistyped or revoked key was found only when the first generation failed.
`PATCH /setup` now asks the provider about a pasted key before storing it
(`AiService#check_key`, mapped to a response in `ApiKeysController#update`).

The check is one GET to the provider's list-models endpoint, which spends no
tokens and uses none of Gemini's free-tier requests:

| Provider | Endpoint | Key sent in |
|---|---|---|
| Anthropic | `https://api.anthropic.com/v1/models` | `x-api-key`, with `anthropic-version` |
| Gemini | `https://generativelanguage.googleapis.com/v1beta/models` | `x-goog-api-key` |
| OpenAI | `https://api.openai.com/v1/models` | `Authorization: Bearer` |

These are the headers each service's generation calls send
(`#auth_headers`), and a key never goes in a URL. Each endpoint was called
with a made-up key on 2026-11-12: Anthropic and OpenAI answered 401, and
Gemini answered 400 with `API_KEY_INVALID`.

| Provider's answer | Result | Key saved | What the person sees |
|---|---|---|---|
| 2xx | `:accepted` | yes | "API key saved. You're all set!" |
| 401, or Gemini's 400 naming `API_KEY_INVALID` | `:rejected` | no | the bad-key sentence, on the Setup form |
| 403 | `:refused` | yes | saved, with a warning that the provider refused the check |
| no answer, a timeout, 429, 5xx, anything else | `:unanswered` | yes | saved, with a warning that the key hasn't been checked |

- **An empty balance is not detected.** A list-models call succeeds on an
  account with no credit. Catching that needs a call that generates
  something, which costs a fraction of a cent and one Gemini free-tier
  request. The owner chose the free check (2026-11-11); the key hold in
  `docs/decisions/pausing-generation.md` covers an account that turns out to
  have no credit.
- **A 403 saves with a warning** (owner, 2026-11-11). A 403 can mean a
  region or account restriction on the models list while the key itself
  works, so refusing to store it would lock out a usable key. Outside the
  check a 403 still reads as a bad key (`AiService#raise_if_key_rejected`).
- **Only a rejection blocks the save.** An outage at the provider must not
  stop someone finishing Setup, so every answer that is not a clear "this
  key is wrong" stores the key and says what was not confirmed.
- **A key that was not saved changes nothing.** The stored keys, the
  provider in use and `users.generation_account_failures` stay as they were;
  only `User#store_api_key` resets the key-hold count. The form comes back
  with the language the person chose still selected, and the key field
  empty, since a key is never echoed.
- **The check waits 3 seconds to connect and 5 for the reply, once**
  (`CallProfiles::KEY_CHECK_OPEN_TIMEOUT`, `KEY_CHECK_READ_TIMEOUT`). It
  runs inside the request, so its connection has no retry middleware and
  the page waits 8 seconds at most.
- **It does not go through `call_and_log`.** It has no prompt, purpose or
  `AiService::Request`, so it reads no trial allowance and no generation
  deadline. `ApiKeysController` does not declare `ProviderCallLimits`, so a
  check never counts toward a trial's shared provider-call limits.
- **It writes no usage row.** The readiness spec proposed a row under a new
  purpose. Three things count rows without asking what they were for:
  `TrialAllowance` and `TrialStatus` count every row for the user and
  provider, whichever key paid, so a trial account checking a key of its
  own would spend one of the trial's daily calls; the Account page's
  request count and its "unpriced" count (`ApiUsage.own_key_totals`) would
  include a call that was never billed; and a rejected key's row would
  record a call under a key the account never held. A new purpose would
  also need an exception in each spec that holds `ApiUsage::PURPOSES` equal
  to `CallProfiles::BY_PURPOSE`, `FakeService::REPLIES` and the request
  snapshots, none of which a GET with no prompt fits. The check logs one
  line instead: `[key_check] provider=<key> result=<result> status=<status>`,
  or `error=<class>` when no answer came.
- **Nothing about the key is logged.** The line above carries no key and no
  provider body; OpenAI's 401 body quotes part of the key. `api_key` is
  filtered from request logs by the `_key` entry in
  `config/initializers/filter_parameter_logging.rb`.
- **The fake provider is never checked over the network.**
  `FakeService#check_key` answers `:accepted`. It has no key pattern, so
  Setup cannot store a fake key anyway; seeds, trials and the preview seed
  write keys through the model and make no check.
- **Saving a key is rate-limited**, since the check lets someone test keys
  they did not create: `ApiKeysController::KEY_SAVES_PER_HOUR` (10) per
  account and `KEY_SAVES_PER_HOUR_BY_IP` (30) per address, counted on every
  save that carries a key, for every account. A preferences-only save is
  not counted. Past either, the form comes back with a 429 and no provider
  is called. Like the other caps these are starting values, not measured
  ones.
- **In specs the check is stubbed to `:accepted`**
  (`spec/support/key_check_helpers.rb`), so no spec reaches a provider. A
  spec of the check itself is tagged `real_key_check` and swaps only the
  connection's adapter through `stub_key_check`.
