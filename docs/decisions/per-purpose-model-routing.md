# Per-purpose model routing

each provider picks its model from its own
`MODEL_FOR_PURPOSE`, keyed by the same `purpose` string `ApiUsage` records,
and falls back to its `DEFAULT_ROUTE` for any purpose not listed. The tables
are per provider because the providers share no model names and turn thinking down
differently (`effort` on Claude, `thinking_level` on Gemini,
`reasoning.effort` on OpenAI). Each provider reads the purpose from the
request `call_and_log` hands to `#call`. Because an unlisted purpose falls
back silently, `spec/services/model_routing_spec.rb` fails on a key with no
row in `CallProfiles::BY_PURPOSE`, so a typo cannot quietly route nothing.

**OpenAI** sends generation and its retry to `gpt-6.1-sol` at `high`
effort, the section judge to `gpt-6-astra` at `low`, and everything else to
`gpt-6-sol` with reasoning off (`none`). None of these routes has been
compared against another model, because `script/compare_models.rb` runs
only Claude. A capped OpenAI call normally sends effort `none` from
`OpenaiService::REASONING_OFF`, its counterpart to `THINKING_OFF`, because
`max_output_tokens` caps reasoning and reply together. GPT-6.1 Sol and
Astra have no `none`, so a capped purpose can go to either only when its
route carries a `reasoning_allowance`. That allowance keeps the route's
effort and adds itself to the cap. The judge's is 25,000 tokens,
OpenAI's suggested starting reserve for reasoning and output, so a judge
call can cost up to 26,200 output tokens at Astra's $50 per million. The
judge still runs on the 45-second `READ_TIMEOUT`, and one that runs out of
time or budget falls back to the draft, like any other judge failure. A
route with an allowance also makes its timeout final, as a long-running
call's is, so a timed-out judge call is not sent again. Low is Astra's
lowest effort. Nobody has measured whether the judge fits that
timeout, or what it costs per day.

`generate_exercise` goes to `claude-opus-5-5` at `medium`
effort, not `low`, because nothing measures whether `low` holds quality.
Opus 5.5 replaced Opus 5 on this route because it costs less ($4/$20 per
million tokens against $5/$25) on the same tokenizer and context; `medium`
is also its default effort, stated explicitly so a change to that default
cannot move this route silently. Thinking cannot be turned off on Opus 5.5,
which this route never asked for anyway: `ClaudeService#request_body` sends
no `thinking` field unless the request carries `max_tokens`, and
generation's profile sets none. Generation
keeps thinking on and the 16,000-token `MAX_TOKENS`, and Opus 5.5 shares
Sonnet 5's tokenizer, so that cap covers the same output. What changes is latency, which
matters less than it would on a request: every generation runs in a job
under the 300-second `GENERATION_READ_TIMEOUT`, so a slower model makes a
user who opened an empty dashboard wait longer but does not fail sooner.
`retry_section` is billed separately, but it uses the same route on each
provider, because it is a narrower generation call rather than a different
kind of work.

The default route is `claude-sonnet-5-5` at an explicit `effort: "high"`,
5.5's own default, stated so a change to it cannot move every default-route
purpose silently. Sonnet 5.5 costs the same as Sonnet 5 and shares its
tokenizer, but its effort levels are recalibrated, so every uncapped
default-route purpose changed cost and latency by an unmeasured amount when
it moved.

`judge_section` goes to `claude-sonnet-5-5` at `effort: "high"`, named explicitly even though it
is the default route, so usage rows and the comparison tooling agree on what
ran. Sonnet first because the judge has to read code carefully and answer in
a closed vocabulary, which is where a smaller model's false rejections would
show. Haiku 4.5 is the comparison candidate at half the price;
`script/compare_models.rb judge` runs one stored day's draft through both,
and `judge_fixtures` runs both over the fixture set with its expected
verdicts. Both were run on 2026-10-09, and **the route stays on Sonnet**,
which is now a measurement rather than a default.

Over the 23 judge fixtures, Sonnet returned valid output 23 times to
Haiku's 21 — Haiku's two failures were `TruncatedResponseError` at the
1,200-token cap, so it did not fit the budget the route gives it. Sonnet
detected 5 of the 9 planted problems against Haiku's 1, falsely rejected 1
of the 14 sound fixtures against Haiku's 4, kept 5 of the 6 keep-expected
fixtures unedited against Haiku's 4, and solved 9 of 9 blind against
Haiku's 7 of 8 with 1 mismatch. The false-rejection count is the number
that decides it: a judge that rejects a sound section costs a retry and
then a dropped section, and Haiku rejects four times as many. Sonnet was
also *faster* over the set, 69.0s against 91.2s, so the $0.19 against
$0.08 buys latency as well as accuracy. Sonnet's per-principle detection
was reasoning_failure 2/3, scope_mismatch 1/1, underdetermined 2/3,
unstated_prerequisite **0/2** — that last one is the gap worth knowing
about, since the Ruby `Thread` incident this stage exists for is an
unstated prerequisite.

A live three-section day told the same story. Sonnet edited the code
review and the security review for leakage and kept the design comparison
with a matching blind solve; Haiku **rejected** that design comparison as
a `scope_mismatch` while solving it correctly. A rejection the judge's own
solve contradicts is the shape of failure that costs a section, and it is
more reason to leave
`JudgedGeneration::REJECT_SOLVE_MISMATCH_BELOW_PRINCIPAL` false.

Review stays on `claude-sonnet-5-5`, and `duck_thread` and
`pseudocode_translate` stay there too. All three comparisons were run on
2026-10-09 and none of them argues for a move.
`script/compare_models.rb` runs a stored day through both
models of a pair and prints the results with tokens and time for a person to
judge.

**Review against `claude-opus-5-5`:** the two agreed on all three of a
stored day's ratings (beginner, beginner, solid). Opus took roughly twice
as long on every section (16.5s against 7.1s, 24.4s against 9.3s, 13.3s
against 8.4s) and wrote far more output at twice Sonnet's list price per
token, so the run cost about four times as much for the same grades. Review is a request the engineer waits on, so paying four
times as much to wait twice as long for the same answer is the wrong
trade.

**The duck against `claude-haiku-4-5`:** Sonnet answered in 2.4s on
**54 input tokens**, Haiku in 1.6s on **806**. That gap is the caching bet
in `conversational-calls-send-real-turns.md`, measured: Sonnet read the cached prefix and Haiku could not, since
the duck's prompt sits under Haiku's 4,096-token cache minimum. Moving the
route would end the caching and eat most of the headline saving. Both
answers were usable; Sonnet's gave a concrete analogy and stayed inside
what was on screen.

**Pseudocode translate against `claude-haiku-4-5`:** this is the one
arguable move, and it is still a no. Both produced a correct, equivalent
`merge_ranges` at near-identical speed (1.6s each, 576 against 426 input
tokens), but **Haiku's omitted the `.dup` and so mutated the caller's
input arrays** where Sonnet's did not. The page captions this output as
the engineer's plan implemented literally, and the engineer is graded on
it, so a silent aliasing bug in the demonstration is worse than its cost.
One sample is thin evidence; re-run it before moving the route on this.
No production response had a `pseudocode_to_code` answer to replay, so the
input was a local section built from `FakeService`'s canned problem set;
only the two models' output is real.

Two constraints apply before routing any of them, and this paragraph is
where they are stated. `ClaudeService#request_body` turns thinking off whenever a request carries `max_tokens`,
using the routed model's entry in `ClaudeService::THINKING_OFF` (`between_tools`
on Sonnet 5.5, `disabled` on Haiku 4.5). Opus 5.5 has no thinking-off setting
and no entry, so a capped purpose cannot move to Opus: the call raises before sending. And Haiku 4.5 caches only a
prompt of 4,096 tokens or more, above the duck's system prompt, so moving
`duck_thread` there ends the caching bet described in
`conversational-calls-send-real-turns.md`.
