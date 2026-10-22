# Conversational calls send real turns

`AiService#duck_response` and
`#answer_follow_up` pass prior turns to `AiService.request_for` as
`history:` — an ordered
`{ role:, content: }` array — while `prompt` carries only the new user turn,
and the section/review context that is stable across a thread lives in
`system`. `ClaudeService` renders `history` as a Messages API `messages`
array; `GeminiService` folds it back into `input` via
`AiService#flatten_history`, because the Interactions API has no equivalent
shape (its stateless multi-turn form is a `Step[]` whose model steps must be
replayed exactly as received, and only assistant *text* is stored here).
`history` began as an optional keyword on `#call`, added after
`cache_system:` and `max_tokens:`. All three are now fields of
`AiService::Request`: `cache_system` and `max_tokens` are set per purpose in
`CallProfiles::BY_PURPOSE`, and `history` is a per-call value. The
additive-keyword pattern was replaced because each new keyword meant editing
five `app/` files and every spec that overrode `#call`, while the settings are
facts about a purpose. Every other caller leaves `history` empty and is
byte-identical. Two specs hold that jointly, because neither can alone —
`spec/services/provider_request_characterization_spec.rb` records the body
each purpose's request sends to each provider and fails on any changed byte,
and `ai_service_spec`'s "single-shot purposes" group drives the other public
entry points and asserts the history each one's request reaches `#call` with
is empty. **The `duck_thread` profile sets `cache_system: true`; the other
conversational caller's profile does not.** Counted with `count_tokens` against `claude-sonnet-5` (5.5 shares its tokenizer)
rather than estimated from characters, the merged duck prompt runs 993-1,182
tokens across the stored `code_review` exercises — median 1,059 — and 1,364
for the largest excerpt `RealSource` can actually produce. That last figure
predates the current-schema block a grounded migration day now adds, so
those prompts run larger, which only strengthens the case for caching.
Against Sonnet 5.5's 512-token minimum every one of those prompts caches,
the shortest sections included.

**It is a bet, not a free win, and this is the shape of it.** A thread is
multi-turn by design but nothing forces a second turn, and the first turn of
every thread pays the write. Writing the prefix costs 1.25x and reading it
0.1x, against 1x per uncached turn, so a thread that stops after one turn
costs 25% more than it would have, a two-turn thread saves 32.5%, and a
three-turn thread saves 52%. Taking the most pessimistic reading — that no
multi-turn thread ever runs past two turns — the write still pays for itself
unless **more than about 72%** of duck threads are single-turn. The
five-minute cache lifetime sits inside that bet: turns seconds apart read the
entry, and someone who wanders off and comes back pays a second write.

**Nothing measures that share yet.** Threads are now stored
(`the-duck-thread-is-stored.md`), but nothing reads them, and a cleared
thread keeps only its count. `ApiUsage` rows with `purpose: "duck_thread"`
are still the way to check this assumption: counting them per user per day
gives the thread lengths once the feature has real traffic. Until then the
72% figure is the argument, not evidence.

Two numbers here have been wrong before, both from estimating at 3.5
characters per token. Real text in these prompts runs 2.83-2.94, so the
estimates read about 20% low, which is what made the median look like it sat
below the minimum when it does not. Re-measure rather than re-derive.

**`answer_follow_up` stays uncached, and that is checked rather than
inherited.** Its system prompt carries the question and a review summary
instead of the section's code, measuring 533-604 tokens. That cleared nothing
against Sonnet 5's 1,024-token minimum; against Sonnet 5.5's 512 it is
cacheable. Caching it is the same bet the duck makes, and it has not been
taken: follow-up threads are unmeasured, so the prompt, history and caching
choice stay as they were.

What the turn conversion itself buys is that a user typing `You:` into the
duck box can no longer forge an assistant
turn — but only on the Claude and OpenAI paths, where `history` reaches the
provider as real turns (`messages` on Claude, `input` items on OpenAI's
Responses API). This is the second Claude/Gemini asymmetry:
`GeminiService` still goes through `#flatten_history`, which re-renders the
same `You:`/`Them:` lines into `input` that made the forgery possible before
role-tagged turns existed, so the vector is unchanged for Gemini users. This
is a known, accepted gap rather than a defect to fix here — closing it needs
the Interactions API to offer a real turn array, which it does not.
