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
connection stays checked out for the whole provider call. That is within
the pool sizing in `.claude/rules/deployment.md`
(`lib/boot/database_pool.rb`), which already counts one connection per
worker thread: the provider worker's 3 threads against a pool of 17. The
concept reference job makes one call and starts no threads of its own, so
it needs no more than its thread's own connection.

## A direct database connection

A session lock needs every query of the hold to reach the same database
session. A pooler in transaction mode, such as PgBouncer, hands each
transaction to whichever server session is free, so the unlock could reach
a different session and the lock would stay held until the pooler closed
the first one. The app connects to Railway's `Database` service directly.
Put a pooler in front of it only in session mode, or move this claim to a
transaction-level lock first.

## When the unlock fails

If the connection died during the block, the unlock fails too. `.release`
logs that failure and returns, so the block's own error, such as a
`ProviderError` the job turns into a failure note, still reaches the
caller. Nothing is lost by not unlocking: the lock ended with the session.

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
