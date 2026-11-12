# `CallerZoneThread`

`CallerZoneThread.start` is the one place a fan-out thread starts
(`ReviewGrading` and `JudgedGeneration`). It does two things for the work it
runs.

## The caller's time zone

`Time.zone` is per thread, so a plain thread starts in the default zone. The
thread runs the work inside `Time.use_zone` with the zone the caller had, so
every `ApiUsage` row one fan-out writes lands on the same `date`.

## Active Record's executor

The work also runs inside `ActiveSupport::Executor.wrap` (#754). Active
Record registers three hooks on that class in
`activerecord/lib/active_record/railtie.rb` (`active_record.set_executor_hooks`):

- `QueryCache::ExecutorHooks` turns the query cache on for the thread and
  clears it when the work ends.
- `ConnectionPool::ExecutorHooks` releases the thread's connection when the
  work ends, unless a joinable transaction is still open on it.
- `AsynchronousQueriesTracker` tracks `load_async` queries.

Without the wrap, a connection the work took with `lease_connection` (or the
soft-deprecated `ActiveRecord::Base.connection`, which `DailyResponse` uses
for quoting) stayed checked out on the dead thread until the pool's reaper
found it. Plain model reads and writes already return their connection in
Rails 8.1, because `with_connection` hands out a non-sticky lease.
`spec/clients/caller_zone_thread_spec.rb` holds the executor, the query cache
and the released connection.

### Why not `Rails.application.executor`

The Rails threading guide wraps thread work in `Rails.application.executor`.
That class is a subclass of `ActiveSupport::Executor`, so it runs the same
Active Record hooks, and in development it also runs
`Rails::Application::Finisher::InterlockHook`, which takes a share of the
code-reload lock (`ActiveSupport::Dependencies.interlock.start_running`). The
hook is registered only when reloading is on, so test and production never
take it.

That share deadlocks a fan-out in development. Every caller of
`CallerZoneThread.start` runs inside a request or a job, so it already holds
a share and then joins its threads. When a file changes, the next request's
reloader asks for the exclusive unload lock and waits for that share. A
`ShareLock` lets waiting exclusive requests go first, so a thread that asks
for a share after that point waits behind the reloader, the parent waits on
the thread, and nothing moves. The dashboard polls every few seconds while a
set generates, so a file saved during a generation is enough.

`ActiveSupport::Dependencies.interlock.permit_concurrent_loads`, the guide's
answer, does not help: in activesupport 8.1 it is a no-op
(`active_support/dependencies/interlock.rb`, "Soft deprecated"). Even before,
it yielded the parent's share only to loads, never to an unload.

`ActiveSupport::Executor` itself carries the Active Record hooks without the
interlock hook or the `active_support.reset_execution_context` hooks
(`ExecutionContext` and `CurrentAttributes`, which the app does not use). The
parent's share keeps code from unloading only while the parent waits on its
threads. A thread it stops waiting for, such as `ReviewGrading`'s difficulty
assessment after its grace period, runs on without a share once the request
ends, so in development a reload in that window can unload code under it. The
plain thread before #754 had the same exposure.

### What the wrap changes

- The query cache is on in a fan-out thread, as it already is in the request
  or job that started it. A thread's cache clears on its own writes, not on
  another thread's, so a thread that reads the same row twice with no write
  between sees the first answer. Locked reads and `reload` bypass the cache.
  The trial cap check stays fresh: every `call_and_log` writes a usage row,
  and that write clears the thread's cache before its next call checks the
  count.
- `ExecutionWrapper.wrap` reports an exception that escapes the work to
  `Rails.error` as unhandled (`source: "application.active_support"`) before
  it re-raises, and the caller still gets it from `Thread#value`. The app
  subscribes no reporter.
- A thread the caller stops waiting for, such as `ReviewGrading`'s difficulty
  assessment after its grace period, still releases its connection when its
  work ends.
