# app/services/generation_deadline.rb

## `#ensure_fits!`

It compares the call's worst case, retries included, with the time left,
rather than only checking the start time. Checking only the start would let a
call begun a second before the deadline run its whole worst case past it, and
the claim window would have to cover that overrun.

Callers check after building the request, just before the call, so time spent
preparing it (planning, ladders, rendering the prompt) is already counted.
`AiService`'s draft, judge and retry paths do this. A judge stopped here
becomes a fallback that keeps the draft, and a stopped retry drops its
section, which is what any failed call already does in `JudgedGeneration`.

## `NONE`

Callers with no deadline (first generation) get it by default, so `AiService`
never branches on whether a deadline exists.
