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
  a failed save never resets the key-hold count. The form comes back
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

- **Where the person sees it.** The rejection is shown in the page alert
  and again directly above the key field, which takes focus on that render,
  so the browser brings the field, Save and the offer below into view
  without a script (`docs/code-notes/app/views/api_keys/edit.html.md`).
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

## A stored key can be removed

Decided by the owner on 2026-11-12. Before this, a stored key could be
replaced but never deleted, short of deleting the account.

- **Where.** Setup's Connection card lists each stored provider under
  "Saved keys", marks the one in use, and gives each a button named for it
  ("Remove Claude key"). The key itself is never rendered.
- **The request.** `DELETE /setup/keys/:provider`, a plain form post, goes to
  `ApiKeysController#destroy`. The browser asks for confirmation first
  through the `loading-form` controller, as account deletion does.
- **What is deleted.** `User#remove_api_key` takes the provider's entry out
  of `api_keys` and out of `key_saved_times`. Nothing else about the account
  changes: sets, reviews and usage rows stay, and a review keeps naming the
  provider that wrote it.
- **Removing the last key** leaves `api_keys` NULL and `provider` nil, which
  is the state of an account that never added a key. Every page that
  requires a provider already redirects such an account to Setup
  (`ApplicationController#require_provider`; Setup, Account, Welcome and
  the sign-in, authenticator, trial, profile and push-subscription
  controllers skip that check), and
  `ScheduledGeneration.users` already leaves it out, so neither needed a
  change. `provider` is cleared and not left naming the removed key's
  provider, so the Account page and a failure message cannot name a provider
  the account no longer has a key for.
- **Removing the key in use while others are stored** switches `provider`
  to the most recently saved of the keys that remain
  (`User#provider_after_removing`). A key with no recorded save time ranks
  behind every key that has one, and so does a time that cannot be read.
  Ties go in `AiProvider.keys` order. Removing a key that is not in use
  leaves `provider` alone.
- **Save times are a column of their own.** `users.key_saved_times` maps a
  provider to the ISO 8601 time its key was saved. The alternative was to
  read the order of the `api_keys` map, which today happens to be insertion
  order. A column states the fact; an ordering is something a refactor of
  how the map is merged or serialized could break without any spec
  noticing. It also leaves the encrypted map's shape and its validator as
  they were, so code from before this release reads and writes the map
  unchanged during a deploy or a rollback. `User#store_api_key` and
  `#remove_api_key` assign `api_keys` and `key_saved_times` together
  through one private method, which also drops a time for a provider with
  no stored key, so writes by this code cannot leave the two disagreeing.
  After a rollback, older code replaces a key without touching
  `key_saved_times`, so a time can be older than its key. The only effect
  is that a later removal may hand over to a different key than the newest
  one. A key saved before the column existed has no time.
- **The key-hold count goes back to zero only when the removal changes the
  provider in use**: the key in use was removed, the last key included.
  Removing a key that is not in use leaves the count and the hold alone,
  because the count describes the key in use. `User#use_provider` follows
  the same rule (`docs/decisions/pausing-generation.md`).
- **A failure recorded against the removed provider is cleared in the same
  save.** `users.last_generation_failure_provider` names the provider a
  failed generation ran on. Left in place, the dashboard would go on
  showing "Claude didn't accept your API key" after the app had switched to
  another key, and `MissingSetState` puts a failure today ahead of starting
  a generation. A failure recorded against another provider stays.
- **A provider choice is re-checked under the row lock.** Before keys could
  be removed, a stored provider stayed stored, so `PATCH /setup` checked
  the "Provider in use" choice against the account as loaded. A Remove in
  one tab followed by that choice from a page loaded earlier would then
  put a removed provider in use. `ApiKeysController#save_preferences` now
  reads `stored_providers` inside the lock, and a provider with no
  stored key saves nothing and returns to Setup with "That provider has no
  saved key, so nothing was changed." That replaces the earlier behaviour,
  which ignored such a choice and reported "No changes made."
  `User#provider_has_a_stored_key` still skips an account with no keys
  map: a trial account names a provider while holding no keys
  (`User#start_trial!`), and so does an anonymized one.
- **Every write in the controller that follows a reload goes through
  `#with_account_locked`**: the key save, the removal and the preferences
  save. It takes the row lock and writes nothing for an account deleted in
  another browser since the request began, and each action then sends the
  browser to sign in. Before this the preferences save had the lock
  without that check, so a language-only save landed on an anonymized row
  and reported success.
- **Under the user row lock.** The keys are one encrypted map written whole,
  so `ApiKeysController#remove_key` removes inside `with_lock`, which
  reloads the row: a key saved in another tab meanwhile stays. An
  anonymized account gets no write and the browser is sent to sign in, as
  with a save.
- **A provider with no stored key is refused**, an unknown name included:
  the account is unchanged and Setup says "There is no saved key for that
  provider, so nothing was removed." The posted name is never echoed.
- **Removal is not rate-limited** and calls no provider.
- **A generation already running finishes.** It holds the key in memory.
  If it then fails, that key's failure is not recorded, and a daily
  generation leaves a message that names no provider; see "A call that
  outlives its key" below.
- **Trials.** `User#on_trial?` is "has a trial and no key in use", so an
  account with an unfinished trial counts as on trial again once its key is
  gone. With `provider` nil there is no house key to resolve, so such a
  trial is not active until the account has a provider again. Trials are
  off for this release; a spec pins `on_trial?` and nothing else was
  designed for the case.
- **What the person is told**, by `ApiKeysController#destroy` from
  `User#remove_api_key`'s outcome through `KEY_REMOVAL_MESSAGES`, which
  raises on an outcome it does not hold:

| Outcome | Notice |
|---|---|
| `:removed` | "Your %{provider} key was removed." |
| `:switched` | "Your %{provider} key was removed. %{in_use} is now the provider in use." |
| `:last_removed` | "Your %{provider} key was removed. New sets stop until you add a key." |

  The confirmation before it uses the same three cases, read from
  `User#key_removal_outcome`, so it names the provider that would take over
  or says that sets stop. Providers are named by `AiProvider.label`, as the
  "Provider in use" choice beside the list names them.
- The setup failure's next step for an own-key account now ends "If they
  look right, remove the key and add it again."

## A call that outlives its key

A generation holds its key in memory for the whole call, which can run for
minutes. The person can remove, replace or switch the key meanwhile. The
jobs used to write the old key's failure anyway and only left it out of the
key-hold count. The dashboard then showed "Claude didn't accept your API
key" to an account that had already moved to another key, and
`MissingSetState` puts a failure today ahead of starting a generation, so
no set was started with the new key.

- **The rule has one home.** `User#key_in_use` is the provider and key in
  use. A job notes it before the call. When the call fails, the job reloads
  the account under the user row lock and writes through
  `User#report_call_failure(key_used)`, which runs the write only when
  `key_in_use` is unchanged. Otherwise the old key's failure is never
  written.
- **What a call with a changed key clears.** Only a failure recorded
  against the call's own provider (`last_generation_failure_provider`
  equal to the provider the call started with). A failure recorded against another
  provider stays: a newer attempt on the key that took over may have
  written it, and clearing it would erase that attempt's message and its
  recovery text. A message that names no provider ("Settings or another
  set changed", "today's set was kept") stays too. Nothing ties it to the
  call that is reporting, and each such message is about the set or the
  settings and is still true.
- **A regeneration reports only while its claim is its own.** With a key
  replaced by another key for the same provider, the provider alone cannot
  tell an old call's failure from one a newer attempt recorded on the new
  key. `RegenerateExerciseJob#release` therefore takes the user row lock,
  releases the exercise's claim with its own token, and writes or clears
  only when that release took effect (`Claimable`'s `release_<name>!` now
  returns whether it did). A regeneration whose claim went stale and was
  retaken records nothing and clears nothing, for a provider failure and
  for its "set was kept" and "unusable set" messages alike; the attempt
  that holds the claim writes the outcome. This is the rule
  `GenerateDailyExercisesJob#persist_failure` already followed. The lock
  order is user, then exercise.
- **A call that started with no provider records nothing and clears
  nothing.** A job queued before the last key was removed starts with
  `key_in_use` of `[nil, nil]`, `AiService.for` raises `SetupError`, and
  the two values still compare equal. Recording that would leave a setup
  failure on the account, and a key added afterwards would find it ahead
  of starting a generation. A trial account has a provider and no key of
  its own, so its failures are still recorded; only a nil provider is
  skipped.
- **`GenerateDailyExercisesJob`** applies it inside `persist_failure`, after
  the claim check and the `set_today?` branch, to a provider or setup
  failure and to the "every section failed its quality check" message.
- **The daily job records a neutral message when the key changed.** The
  day has no set, and a dashboard may be polling `GET /dashboard/status`
  for one. Recording nothing left that page with no set, no failure and no
  job: a visit after the key change had enqueued a second job, which
  stopped because the first still held the generation claim, and the poll
  answered "pending" until it gave up with "This is taking longer than
  expected". So the job records
  `GenerateDailyExercisesJob::SUPERSEDED_MESSAGE` ("Settings or another set
  changed while this set was being prepared. Generate again when ready."),
  the message it already uses when settings moved under a call. The poll
  then answers "failed", the page reloads, and the person sees a true
  sentence with "Try again". It names no provider, so it says nothing
  about the old key, and saving or removing a key leaves it in place. It
  replaces a failure left for the call's own provider. It is passed to
  `User#report_call_failure` as `when_key_changed:`, so the rule keeps one
  home; the job only supplies what to write.
- **When the neutral message is not recorded.** A failure or message
  already recorded today that is not the call's own provider's stays as it
  is, since the poll already has an answer and a newer attempt may have
  written it. An account left with no provider in use gets nothing either:
  every page that requires a provider sends it to Setup, so no dashboard is
  waiting, and a message would only sit in front of the first set after a
  key is added. A call that started with no provider records nothing for
  the same reason.
- **The job does not enqueue a replacement.** Its own queue permit would
  discard the new job. The status endpoint does not guess from the claim
  either: a queued job holds no claim yet, and the page would reload in a
  loop.
- **`RegenerateExerciseJob`** applies the rule to a provider or setup
  failure and stays silent when the key changed. It takes the user row
  lock, releases the exercise's claim with its token inside that lock, and
  reports only when the release took effect, so the order is user, then
  exercise. Today's set exists, so once the claim is released the status
  endpoint answers "ready" and the waiting page reloads onto the set;
  nothing is left polling. Its "today's set was kept" messages are still
  recorded whatever the key: the person asked for a new set and is looking
  at the old one, and the message is the only thing that says why.
- **A key changed after the failure was written.** Removing a key clears a
  failure recorded against the removed provider. Saving a key clears one
  too, and so does switching between stored keys; see "Saving a key
  clears that provider's failure" and "Switching providers clears the old
  provider's failure" below.

## Saving a key clears that provider's failure

Decided by the owner on 2026-11-12 (#780). After "Claude didn't accept your
API key", a person who pasted a working Claude key still landed on the
failure card, because a failure today ranks ahead of starting a generation
and `User#store_api_key` touched no failure column.

- **The saved provider's failure is cleared**, as an assignment in the same
  save as the key (`User#forget_generation_failure_from`, which
  `#remove_api_key` uses too). The checked save and the save without
  checking both go through `#store_api_key`, so both end on a dashboard
  that starts a set. A key that is rejected is not saved and clears
  nothing.
- **So is a failure recorded against the provider the save switches away
  from.** A saved key always becomes the key in use. With Claude failed and
  a GPT key pasted, the Claude failure would describe a provider the
  account has just stopped using and would still hold back the first set
  on the new key. The person's intent is the same as when they replace the
  failed key: the problem is dealt with, start a set.
- **Anything else stays**: a failure recorded against a provider that is
  neither the one saved nor the one that was in use, and a message that
  names no provider. The quality-check message names the provider whose
  drafts failed, so it is cleared like that provider's failure; see "The
  quality-check message carries its provider" below.

## Switching providers clears the old provider's failure

Decided by the owner on 2026-11-12. After "Claude didn't accept your API
key", a person who chose their stored GPT key under "Provider in use" still
saw the Claude card, and a failure today ranks ahead of starting a
generation, so no set started on the key they had just chosen.

- **A switch that changes the provider clears a failure recorded against
  the provider it leaves**, in the same save, through the method the key
  save and the removal use (`User#forget_generation_failure_from`, called
  from `User#use_provider`).
- **A rate-limit wait goes with it.** "Claude is limiting requests, try
  again in about 2 minutes" says nothing about a call to GPT, and the next
  set runs on GPT. The cost is that the person is no longer told when
  Claude would answer again; they would see that only by switching back
  and trying.
- **A choice of the provider already in use changes nothing.** Setup posts
  the current provider with every preferences save, and that must not
  clear a failure the person has done nothing about.
- **Anything else stays**: a failure recorded against a third provider, one
  recorded against the provider being switched to, and a message that
  names no provider. The quality-check message for the provider left is
  cleared, since it carries that provider.
- **The failure line still names the provider that was tried.** A failure
  stores its provider, and `User#generation_failure_message` words the
  line from that and not from the provider in use when it is read
  (`docs/decisions/what-a-person-is-told-when-a-provider-fails.md`). That
  still matters wherever a failure outlives a change of provider: the
  third-provider case above, and an account whose provider was changed
  without going through the model's key methods.

## The quality-check message carries its provider

Decided by the owner on 2026-11-13 (#782, item 1, option A). When every
section of a daily set fails its quality check,
`GenerateDailyExercisesJob` records "every section failed its quality
check" with no set for the day, and a failure today ranks ahead of
starting a generation. The drafts were written by one provider, and a
person who moved to another provider was still held behind that message.

- **Stored with the provider whose drafts failed.**
  `User#record_generation_message!` takes an optional `provider:` and
  writes it to `users.last_generation_failure_provider`;
  `last_generation_failure`, the failure kind, stays nil. No column was
  added.
- **Why that shape.** Every reader of the kind treats a nil kind as a plain
  message: `User#generation_failure_message` returns the stored text, and
  `GenerationFailureHelper#regeneration_failure_line` wraps it in the same
  "Couldn't generate" sentence as before. The key-hold count is raised only
  by `#record_generation_failure!`, so the message never counts toward the
  hold and never reads as "check your key". Every reader of the provider
  column is about which provider a failure belongs to:
  `#forget_generation_failure_from` (a key saved, removed or switched away
  from) and `#report_call_failure`'s "own provider" check. Both now treat
  the message as that provider's, which is the decision.
  `#forget_generation_failure_from` clears the message text with the
  provider.
- **What stays provider-less.** `GenerateDailyExercisesJob::SUPERSEDED_MESSAGE`
  ("Settings or another set changed…") is about the account's settings, not
  a provider, and a key change does not clear it (option B was declined).
  `RegenerateExerciseJob`'s "today's set was kept" messages stay
  provider-less too: a set exists, so they never hold back a generation.
- **Rows written before this change** hold the message with no provider and
  behave as they did: nothing a key change does clears them.

### Open items

- `AiService.check_key` and `.skip_key_check` raise `SetupError` for an
  unavailable provider and `ApiKeysController` has no `rescue_from` for it.
  No provider with a key pattern is restricted today, so the path is
  unreachable from Setup; add the rescue when one is.
