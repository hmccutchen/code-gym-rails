# Per-user API keys

Each user provides their own Anthropic, Gemini or OpenAI key, and can keep one for each. Zero shared cost. A pasted key's prefix (`sk-ant-`, `AIza`/`AQ.`, or `sk-proj-`/`sk-svcacct-`/legacy `sk-`) decides which provider it is saved under; the OpenAI pattern requires alphanumerics straight after a bare `sk-`, so it can never claim an Anthropic key whatever order the patterns are tried in. Pasting a key replaces only that provider's key and selects it (`User#store_api_key`); Setup's "Provider in use" radios switch between saved keys without re-entering one, and list only providers with a saved key (`User#stored_providers`). `user.provider` names the one in use, `User#api_key` reads its key, and `AiService.for(user)` dispatches on it, so nothing downstream knows there is more than one. The keys are stored together in `users.api_keys`, a JSON map serialized and then encrypted with `encrypts :api_keys` (ActiveRecord Encryption); no keys stores as NULL, so `where.not(api_keys: nil)` finds the accounts that can call a provider. A map rather than a column per provider keeps adding a provider a matter of adding a class. `users.api_key`, the single-key column it replaced, was ignored for one release while the old code served through the pre-deploy migration, and `RemoveApiKeyFromUsers` dropped it once a production check found no key held only there. Each reviewed response records the provider that wrote it in `daily_responses.review_provider`, so History and the dashboard keep naming it after a switch; a part-reviewed day finished on another provider names the last one. `ResponseReview` sets it on every review, and the preview seed sets it on its seeded one. `AddReviewProviderToDailyResponses` backfilled earlier reviews, storing `unknown` (labelled "AI") for a user whose `api_usages.model` rows name another provider; models were recorded only from 2026-10-01, so a switch before that left no trace, and those reviews keep the current provider's name. A response with none reads as the current provider (`DailyResponse#review_provider_key`, named on the page by `ReviewHelper#review_provider_label`); a production check on 2026-10-14 found no reviewed response without one, so the provider switch no longer labels unlabelled reviews first. Setup says nothing about how providers differ: the prose judge runs on Claude only, and it, structured output and caching change the wording of a review, cost and reliability rather than anything an engineer does differently. The `ACTIVE_RECORD_ENCRYPTION_*` env vars are wired in via `config/initializers/active_record_encryption.rb` (Rails does not read them from ENV on its own); development derives throwaway keys from `secret_key_base` automatically.

## A key is checked when it is saved

Before this, Setup accepted any key whose prefix matched a provider, and a
mistyped or revoked key was found only when the first generation failed.
`PATCH /setup` now asks the provider about a pasted key before storing it.
`ApiKeysController#update` calls `AiService.check_key(provider_key, key)`,
which applies the availability gate `AiService.for` applies and runs the
provider's `#check_key`, and the action maps the result to a response. The
controller names no client class.

**A pasted key must be one run of printable ASCII**, at most
`AiProvider::MAX_KEY_LENGTH` (512) characters, with no space, tab, newline
or other control character (`AiProvider::KEY_SHAPE`). `AiProvider.detect`
applies it before any `key_pattern`, so it is the one place the rule lives:
the patterns anchor only a key's start, and a key travels in an HTTP
header. Before the rule, `"sk-ant-abc\nX-Evil: 1"` was detected as an
Anthropic key, and Net::HTTP raised an `ArgumentError` whose message quoted
it into the log. A key that fails gets the "We don't recognize this key
format" alert, no provider is called, and nothing is stored. `User` does not
validate the shape of stored keys, only that each is a non-blank string
under a known provider, so a key the old code stored in a bad shape cannot
fail an unrelated save; it would still fail at its first provider call.

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
| 401, or Gemini's 400 naming `API_KEY_INVALID` | `:rejected` | no | "%{provider} didn't accept your API key, so it wasn't saved.", on the Setup form |
| 403 | `:refused` | yes | "Saved, but %{provider} wouldn't let the key be checked. If your first set fails, check the key in your %{provider} account." |
| no answer, a timeout, 429, 5xx, anything else | `:unanswered` | yes | "Saved, but the key couldn't be checked with %{provider}. If your first set fails, check the key." |

Neither warning names a status code or guesses a cause, under the rule in
`docs/decisions/what-a-person-is-told-when-a-provider-fails.md`. The second
is worded to be true of a 404 or a 429 as much as of a timeout.

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
- **The key is stored under the user row lock.** The account is loaded
  before the check, which can take seconds, and the keys are one encrypted
  JSON map written whole. `ApiKeysController#store_key` therefore merges
  inside `with_lock`, which reloads the row, so a key saved from another tab
  during the check is still in the map.
- **A deleted account gets no key.** `User#anonymize!` clears `api_keys`,
  and an account can be deleted from another browser while the check runs.
  The store used to put the pasted key back on the anonymized row, where
  nothing would ever clear it. Inside the lock, after the reload,
  `#store_key` now writes nothing when the row is anonymized, and the
  action answers as `require_login` does for a signed-out browser: a
  redirect to `/login` with the sign-in alert, never "saved". The
  save-without-checking path goes through the same method. No other write
  in the controller has a slow step between its read and its save, and
  `preferences_update` never assigns `api_keys`, so it cannot restore a
  key.
- **The whole check is bounded at 8 seconds, once**
  (`CallProfiles::KEY_CHECK_TOTAL_SECONDS`, the sum of
  `KEY_CHECK_OPEN_TIMEOUT`, 3, and `KEY_CHECK_READ_TIMEOUT`, 5). The two
  Faraday timeouts alone do not bound it: Net::HTTP's read timeout starts
  again on every read, so a server sending a byte every few seconds held a
  client for 45 seconds in review, on a web server with three threads.
  `#check_key` wraps the GET in `Timeout.timeout` with the total, and a
  local server dripping one byte a second was cut off at 8.0 seconds. The
  connection is built for this one request and dropped afterwards, so an
  interrupted read leaves no shared state behind. The connection has no
  retry middleware.
- **Any error inside the check is `:unanswered`.** `#check_key` rescues
  `StandardError`, the total timeout included, and logs the error's class
  and never its message, since a message can quote a header. A transport
  failure (`Faraday::Error`, `Timeout::Error`) is logged at info. Any other
  class is logged at error level: it is a bug in the check, and at info it
  would save every key with the "couldn't be checked" warning unnoticed.
- **A pasted key is trimmed at both ends before anything reads it.**
  `ApiKeysController#pasted_key` removes leading and trailing characters in
  Ruby's `[[:space:]]` class: space, tab, newline, carriage return, form
  feed, vertical tab, and Unicode spaces and separators such as the
  non-breaking space (U+00A0), which a copy from a web page can carry and
  `String#strip` leaves in place. Nothing inside the key is removed, and
  the shape rule is unchanged, so a space of any kind inside a key is still
  refused. A zero-width space (U+200B) is not in that class and is refused
  too.
- **Only a posted language is written with the key.** The account is read
  before the check, so writing its language back afterwards would undo a
  change made in another tab meanwhile. Inside the lock the language is
  assigned only when the form posted one.
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
  save that carries a key, a badly shaped one included, for every account. A preferences-only save is
  not counted. Past either, the form comes back with a 429 and no provider
  is called. Like the other caps these are starting values, not measured
  ones.
- **In specs the check is stubbed to `:accepted`**
  (`spec/support/key_check_helpers.rb`), so no spec reaches a provider. A
  spec of the check itself is tagged `real_key_check` and swaps only the
  connection's adapter through `stub_key_check`.

### A rejected key can be saved without checking

Decided by the owner on 2026-11-12. When this shipped, no check had been
seen to succeed with a real key: each endpoint was confirmed only by the
rejection it gave a made-up one. A check that wrongly rejected a working
key would lock a paying person out of Setup with no way round it, so a
rejection is never final.

- **What the person sees.** The form that follows a rejection keeps its
  Save button and adds, below it, the line "If you're sure the key is right,
  paste it again and save it without checking." and a second button, "Save
  without checking". The key field is empty, as on every render: the
  rejected key is not put in the page, a hidden field, the session, a cookie
  or the flash, so the person pastes it again. Both buttons are plain form
  submits and need no script; Save is first in the form, so Enter still
  runs the checked save.
- **The server decides when it is offered.** `ApiKeysController` sets it on
  the render that follows `:rejected` and nowhere else: a fresh Setup page,
  an unrecognized-format response and a rate-limited response do not carry
  the button.
- **What the button does.** It posts the same `PATCH /setup` with
  `skip_check=1`. Only that exact value turns the skip on
  (`ApiKeysController::SKIP_CHECK`). The controller then asks
  `AiService.skip_key_check` where it would have asked `.check_key`, and
  everything else runs as for a checked save.
- **What is skipped:** the request to the provider, and nothing else.
- **What is not skipped:** the limit on key saves, the edge trimming, the
  shape rule, the prefix detection and the provider availability gate, each
  with the message it gives a checked save; the store under the row lock,
  which resets the key-hold count as any stored key does; and the rule that
  a blank key field is a preferences-only save.
- **The parameter is accepted whenever it is posted.** No session state
  remembers the rejection. That is no weaker than Setup was before the
  check existed, when every well-formed key was stored unchecked, and the
  save limit bounds it the same way.
- **The notice says it was not checked:** "Saved without checking. If your
  first set fails, check the key in your %{provider} account."
- **`:skipped` is the controller's outcome, not a check result.**
  `AiService::KEY_CHECK_RESULTS` stays the four answers a check can give,
  and `.skip_key_check` returns `:skipped` beside them. The action still has
  one mapping from outcome to response, `SAVED_NOTICES`, which raises on an
  outcome it does not hold.
- **It is logged so the two paths can be counted:**
  `[key_check] provider=<key> result=skipped`, with no key and no status.
  `AiService` writes it, so the line's format has one home.

### Open items

- `AiService.check_key` and `.skip_key_check` raise `SetupError` for an
  unavailable provider and `ApiKeysController` has no `rescue_from` for it.
  No provider with a key pattern is restricted today, so the path is
  unreachable from Setup; add the rescue when one is.
