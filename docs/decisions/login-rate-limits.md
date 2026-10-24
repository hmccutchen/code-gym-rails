# Login rate limits

A 6-digit code is a weak enough secret that the
guessing bound is part of the design, not an optimization. `SessionsController`
caps code requests at 5 per address, code requests at 20 per IP, and
submissions at 10 per IP, all per `LOGIN_RATE_LIMIT_WINDOW` (15 minutes),
via Rails' `rate_limit`, plus code requests at 50 per IP per day and submissions at
10 per address per hour. The per-IP request caps are the ones that bound an
attacker who varies the address rather than hammering one: an unrecognized
address creates an account and sends mail, so without them a single client
could mint unlimited rows and unlimited outbound deliveries. The
per-address submission cap bounds guessing from rotating IPs, which the
per-IP one cannot; its cost is that anyone can start a login for an
address and lock it out of guessing for an hour, which is why it is
hourly and no daily per-address cap exists. Each limit carries an
explicit `name:`, without which Rails would key them into one shared
bucket. `LazyCacheStore` exists solely
because `rate_limit` binds its `store:` at class-load time; resolving
`Rails.cache` per call keeps production on Solid Cache and keeps the limits
testable against the test env's `:null_store`.

The windows are 15 minutes, while a code lives 10 (`LOGIN_CODE_EXPIRY`).
They used to share one constant, so shortening a code's life would also
have loosened every 15-minute limit. A per-address request limit that
outlasts the code still stops fresh codes from resetting the guess count.

Every per-IP limit keys on `request.remote_ip`. Nothing configures trusted
proxies, so whether that is the client's address behind Railway's edge is
unconfirmed. Before going public, run the check in
`docs/passwordless-sign-in-spec-2026-10-23.md` ("Not in this PR: trusted
proxies"). It compares the logged IP from two devices with their real
addresses, and sends a spoofed `X-Forwarded-For` header. Record both
results here.

## The second factor

An authenticator code is also 6 digits, so it gets the same treatment, plus two counts kept on the user row (`docs/decisions/passwordless-sign-in.md`):

- **Second sign-in step** (`SecondFactorChallengesController`): 10 attempts per pending account and 20 per IP, each per `LOGIN_RATE_LIMIT_WINDOW`.
- **Turning the authenticator on or off, and making new recovery codes** (`AuthenticatorChanges`): 10 per account per window, shared by both controllers through one `scope:`.
- **Per challenge:** 5 wrong codes end the challenge, and the next try needs a new request at `/login`. Since that request needs only the address, this limit does not bind on its own: the daily cap does. The count is `second_factor_challenge_failures` on the row, so replaying an older cookie can't reset it, and a request within `User::Authenticator::DOUBLE_TAP_WINDOW` (30 seconds) of the last challenge gets that challenge back with its count kept. For an authenticator account, the per-address request limit above is therefore also what bounds how often anyone who knows the address can issue a new challenge, each of which ends the owner's open one.
- **Per day:** 20 wrong codes in 24 hours refuse every code until the window that began at the first failure ends (`User::Authenticator::DAILY_FAILURES`). The 15-minute limits alone would allow 350,400 guesses a year; the daily cap holds it to 7,300.
