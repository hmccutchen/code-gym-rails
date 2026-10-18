# app/services/generation_deadline.rb

## `#ensure_fits!`

It compares the call's worst case, retries included, with the time left,
rather than only checking the start time. Checking only the start would let a
call begun a second before the deadline run its whole worst case past it, and
the claim window would have to cover that overrun.

## `#guard`

It wraps `JudgedGeneration::Provider`'s callables, so `JudgedGeneration`
needs no deadline of its own. A judge that raises `AiService::DeadlineError`
becomes a fallback that keeps the draft, and a retry that raises drops its
section, which is what any failed call already does there.

## `NONE`

Callers with no deadline (first generation) get it by default, so `AiService`
never branches on whether a deadline exists.
