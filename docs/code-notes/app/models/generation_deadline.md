# app/models/generation_deadline.rb

## `#ensure_fits!`

It compares the call's worst case, retries included, with the time left,
rather than only checking the start time. Checking only the start would let a
call begun a second before the deadline run its whole worst case past it, and
the claim window would have to cover that overrun.

It takes the request, not a purpose, and reads `Request#worst_case_seconds`,
so a blocking request reserves its own shorter read. `AiService#call_and_log`
is the one caller in `app/`, and it checks before anything else, so time spent
preparing the request (planning, ladders, rendering the prompt) is already
counted. A judge stopped here becomes a fallback that keeps the draft, and a
stopped retry drops its section, which is what any failed call already does
in `JudgedGeneration`.

## `#leaving`

Returns a deadline that ends earlier by the time kept back. A retry checks
against `leaving` a judge's worst case, so it starts only when the judge that
checks its output can still run after it.

## `NONE`

Callers with no deadline (first generation) get it by default, so `AiService`
never branches on whether a deadline exists.
