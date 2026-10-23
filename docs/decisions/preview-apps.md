# Preview apps

a Railway PR environment starts with an empty database and
needs no configuration. `railway.toml`'s `[environments.pr.deploy]` block
exports `PREVIEW_APP=1` into both the pre-deploy and server processes, and
`PreviewEnvironment.active?` is the single authority every preview behavior
derives from: `PreviewSeed` (three days of demo content for one account),
`PreviewMail` (inline delivery, so login never waits on a worker), and
`PreviewAutoLogin` (an unauthenticated request is signed in as the seeded
user — and only as an account `PreviewSeed.seeded?` recognizes as its own,
so a real account sitting at that address, which the seeder deliberately
leaves untouched, is never signed into). `PREVIEW_SEED_EMAIL` is now only an
optional override of *which*
account — `PreviewSeed::DEFAULT_EMAIL` covers the normal case — so setting it
at the wrong Railway scope no longer does anything on its own. Nothing in the
repo turns auto-login on outside a PR deployment: `pr` is a hardcoded key
Railway resolves itself, production's
deploy config comes from `[deploy]` which exports nothing, and the app's own
config never sets `PREVIEW_APP`, so `PreviewAutoLogin`
registers its callback — gated on the same `PreviewEnvironment.active?` — only
there; in production the callback is not in the chain at all. `PREVIEW_APP`
is still an ordinary environment variable, though: typing it into a
production or shared-scope Railway variable would enable this, which is why
the name is reserved for PR deployments and set from committed config only.
It skips
the login pages, so signing in as someone else still works, and a deliberate
logout sets a cookie that keeps the reviewer signed out. The seed gives the
account a random password and an authenticator, so auto-login lands past the
setup checks in `ApplicationController`.

**Accepted tradeoff:** a PR app's URL is internet-reachable, so this replaces
"public URL, login wall" with "public URL, no wall" for anyone holding the
link. The seeded account carries `PreviewSeed::DUMMY_API_KEY` and fabricated
history in a throwaway database, so the blast radius is bounded — but the
change is deliberate, not an oversight.

**`DEFAULT_EMAIL` is undeliverable on purpose** (`.invalid`, RFC 2606), so it
can never collide with a real mailbox. The cost is that a preview app's
mail-sending actions (the "Email me this review" button, a password reset
requested for that address) fail loudly rather than silently: `PreviewMail`
delivers inline and production config sets `raise_delivery_errors`. Set
`PREVIEW_SEED_EMAIL` to a real address on the PR environment when a reviewer
needs those paths to work.
