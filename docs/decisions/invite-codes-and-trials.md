# Invite codes and trials

anyone can sign up with an email, as before,
and bring their own key; no code is needed to use the app. An invite code
starts a trial on a house key instead. `InviteCode` keeps only a SHA-256
digest of the 26-character base32 code `script/mint_invite_code.rb` prints
once, with its seats, deadline, trial length and daily cap, and `#redeem!`
takes a seat in one statement against the seat count and the deadline, so
two redemptions cannot both win the last seat. The person picks the
provider: `TrialMode.providers` lists those with a data notice to consent
to and a house key set (Gemini, Claude and OpenAI), and none under the kill
switch.

**Trials are paused (October 2026).** The login page no longer links to
`/trial/start`, so nobody finds a trial without being sent the link. The
routes, invite codes and house-key gates are unchanged, and an existing
trial runs to its end. The open question is cost: on a paid house key the
app pays for every trial call, and Gemini's free tier is one shared pool
too small for a group starting their day at once. Restoring the link (and
the `sessions.new.trial_link` copy) reopens trials. Until then, the Account
page's monthly usage table shows own-key accounts what they send.

**Two ways in.** `/trial/start` is public: an email, the code, a
provider and the consent checkbox. It checks the code (`#available?`)
before mailing anything, mails a login code through the same
`LoginCodeRequests` concern and limits the login form uses, and keeps a
`PendingTrial` in the session. Entering the emailed code takes the seat and
starts the trial, so nobody can spend a seat on an address they cannot
read; asking for a plain login code drops the pending trial. A signed-in
account with no key uses `/trial`, which asks for the code and provider
only.

**A trial is a `trial_ends_at`, nothing more.** `User#start_trial!` runs
under the row lock, refuses an account with a key of its own or one that
has had a trial, takes the seat, and sets `provider` to the choice and the
end to the last day's end in the user's zone, counted from when the seat
is taken rather than from consent, which can come the day before.
`trial_active?` needs the end in the future, `TrialMode.enabled?`
(`TRIALS_DISABLED` is not `"1"`, the kill switch) and a house key for the
provider (`HouseKeys.for`, `HOUSE_<PROVIDER>_API_KEY`, read from ENV at
call time and never stored), and an account that has not been deleted,
since jobs queued before a deletion still load the row by id.
`provider_ready?` is own key or active trial,
behind `require_provider` and the dashboard's on-demand generation; the
nightly batch still selects stored keys, so a trial is generated only when
it opens the dashboard.

**The house key changes the credential and nothing in the request.**
`ProviderCredential.for(user)` hands `AiService.for` the user's own key, no
key, or the house key, and raises `ProviderError::TrialEndedError` for an
ended trial. The service's `house_key?` reaches the per-section threads
through `fresh_service`, is written to every usage row, and is what runs
`TrialAllowance.check!` ahead of the call in `call_and_log`: a trial still
active, since a service built during the trial keeps its house key through
a fan-out or a long job (`ProviderError::TrialEndedError` otherwise), the invite's
`daily_request_cap` on the user's own day (`ApiUsage.requests_on`, counted
by when each row was written in the user's zone, since a job outside that
zone stamps `date` with the server's day) and `HOUSE_<PROVIDER>_DAILY_GUARD`
over the provider's quota day (`AiService.quota_day`: Pacific for Gemini,
UTC otherwise), attempts included, each raising
`ProviderError::TrialAllowanceError` with the seconds until the count resets
and writing no row. The gate counts before its own row exists, so
concurrent calls can overshoot by the fan-out width per account, times
the accounts calling at once; the provider's spend limit is the hard
stop, by design. `spec/services/trial_isolation_spec.rb` pins
byte-identical generation and judge calls for a trial and an own-key twin,
and that nothing in `IsolationScope` (`app/services`, `app/jobs`,
`app/prompts`, `app/clients` and the pure decision objects) or the mastery
and verdict models reads trial state. A trial account's failures read in the
`trial` variant (`ProviderFailureText.variant_for`): the two trial kinds
only exist there, and `daily_limit`, `bad_key` and `out_of_credit` name
the trial's key rather than the reader's, while the rest fall back to the
`own_key` words.

**What a trial account sees.** `TrialStatus.for(user)` is the one reading
of a trial's standing: the day it ends and the days left in the user's
zone, today's calls against the cap (the gate's own query), and the day it
ended, or none when the kill switch or a missing house key ended it early.
`/trial` shows that with the data notice, the dashboard carries one banner
line linking there, and Setup swaps the on-track key guide for a note
linking there while the trial runs. An ended trial still reaches every
page: `require_provider` lets any trial through, each provider call then
fails with the trial-ended sentence through the rescues the surfaces
already have, the dashboard renders a trial-ended panel instead of
enqueuing a set, `/generate` and `/regenerate` refuse with the sentence
(an existing set shows no Generate new set button), and Setup shows the
key guide whether or not the account is on the track. `User#on_trial?`, a
trial with no key of its own, is what every trial page and sentence reads,
and `trial_ended?` is `on_trial?` and not active: a trial account that
pastes a key is an own-key account everywhere, ended or not, since
`ProviderCredential` hands the service that key first. `trial_active?`
takes the clock it is asked about, so `TrialStatus` reads one `now`
throughout. Every trial branch renders only for a trial account, so
existing pages stay byte-identical.
Design in `docs/trial-mode-and-provider-limits-2026-10-06.md`.
