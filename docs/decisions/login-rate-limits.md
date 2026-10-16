# Login rate limits

A 6-digit code is a weak enough secret that the
guessing bound is part of the design, not an optimization. `SessionsController`
caps code requests at 5 per address, code requests at 20 per IP, and
submissions at 10 per IP, all per `LOGIN_CODE_EXPIRY`, via Rails'
`rate_limit`, plus code requests at 50 per IP per day and submissions at
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
