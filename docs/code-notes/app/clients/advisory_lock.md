# `AdvisoryLock`

## What it is for

A claim on work that has no row yet. `GenerateConceptReferenceJob` creates
the user's own reference, so before its first write there is no row to hold
a `Claimable` timestamp (`.claude/rules/patterns.md`, "Claims and lock
order"). `.hold` takes a PostgreSQL session advisory lock on a text key,
runs the block while holding it, and lets go when the block ends or raises.

## Try, never wait

`.hold` uses `pg_try_advisory_lock` and answers `false` without running the
block when another session holds the key. A job that waited would only make
the call the holder already made.

## One connection for the whole hold

A session lock belongs to the connection that took it, and only that
connection can release it. `.hold` runs inside `with_connection`, so the
block's queries, the provider call's usage row included, run on that same
connection and the unlock reaches the session that holds the lock. The
connection stays checked out for the call, which is within the pool sizing
in `.claude/rules/deployment.md`: one connection per worker thread.

## Nothing goes stale

When a worker dies, its connection closes and PostgreSQL drops the lock. So
unlike a timestamp claim, there is no stale window to wait out.

## The key

`hashtextextended(key, 0)` turns the text key into the 64-bit number the
lock takes. Two keys that hashed alike would make one job skip, the same
outcome as a held claim, and the chance is negligible at 64 bits.

## Reentry

The lock is reentrant within one session. Two holds on one connection
would both succeed, which never happens in a worker, where each thread has
its own connection. A spec that needs the key held elsewhere opens a second
connection, since the test suite shares one connection across threads.
