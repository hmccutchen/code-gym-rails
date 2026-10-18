# Two-stage generation

the weekday batch drafts a set, then reads each
section back and decides keep, edit or reject
(`AiService#generate_judged_exercise`, which delegates everything after the
draft to `JudgedGeneration`). It exists because two real sections
shipped broken in the same way. A `code_review` planted on a Ruby `Thread`
needed the engineer to know how threads behave, and a game-flavored one
needed to know that render loops are hardware-dependent. In both the missing
knowledge was not the tagged concept, so `ConceptReference` — which explains
only the tagged concept — had nothing to offer, and the section was
unanswerable for a reason no downstream check could see.

**Every weekday generation, regeneration included.** Judging costs a
second provider call per section and a possible third for a retry.
`GenerateDailyExercisesJob#generate_for(user, judge:)` passes `judge: true`
from the cron branch and, on a weekday, from the on-demand branch too. It
was cron-only at first, but a user who opened the dashboard before their
8am tick got an on-demand set, and the batch then found the day filled, so
an early riser was rarely judged. The cost of the change is a longer
spinner on the dashboard, which is why `dashboard/_generating` polls for
`AiService::JUDGED_GENERATION_BUDGET` rather than the draft's budget alone.
A weekend "generate anyway" set stays on the single-stage path.

**Regeneration is judged on a weekday, under a deadline.**
`RegenerateExerciseJob` calls `#generate_judged_exercise` on a weekday and
`#generate_unjudged_exercise` at a weekend, matching first generation.
Regeneration is the way to get a saved pair of daily kinds into today, so it
should not ship sections first generation would have rejected. A judged day
can take `JUDGED_GENERATION_BUDGET`, 2,302 s, and a claim window that long
would let a crashed worker block `/regenerate` for 38 minutes. So the job
runs under a `GenerationDeadline` measured from the claim, not from job
start, so a slow pickup comes out of the same budget.

- **The deadline** is `DailyExercise::REGENERATION_DEADLINE`: one worst-case
  draft plus one worst-case judge plus `JOB_PICKUP_MARGIN`, 946 + 181 + 60 =
  1,187 s, about 20 minutes. A slow but working provider still gets one
  judged answer. `REGENERATION_STALE_AFTER` adds `WRITE_MARGIN` (60 s) for
  the work after the last call, 1,247 s in all, up from 1,006 s.
- **The rule.** Before each provider call, the deadline checks that the
  call's own worst case (`AiService.worst_case_seconds_for` its purpose)
  still ends in time, and raises `AiService::DeadlineError`, a
  `TimeoutError`, if it doesn't. Checking the worst case rather than the
  clock alone makes the deadline a ceiling on the job: a call begun just
  before it can't overrun.
- **What a stop costs.** The draft check is the job's own: a draft that no
  longer fits ends the run, releases the claim and leaves today's set, shown
  as a timeout. The judge and retry checks run inside `JudgedGeneration`
  through the guarded `Provider`, which needs no change: a judge that can't
  start is a fallback that keeps the draft (reason `deadline`, kept apart from
`timeout` so queue delay doesn't read as a slow judge), and a retry that can't start
  returns nil and drops that section. The sections already kept land, since
  throwing away a judged day over one late retry costs more than one dropped
  section. If nothing is left, `AllSectionsRejectedError` keeps today's set,
  and the job says the new set failed its quality check.
- **What it costs.** A weekday regeneration makes one draft call plus one
  judge call per section (two to four), and up to two retries and re-judges
  per rejected daily kind or one per rotated kind, all within the deadline.
  It used to make one call.

**The judge classifies; it never writes a second draft.**
`JUDGE_SYSTEM_PROMPT` states the principle it turns on: "A question may be
difficult, unfamiliar, or conceptually demanding. Its difficulty must come
from the intended reasoning task, not from unclear wording, missing
information, or accidental prerequisites … Never reject a problem for being
hard." It may rewrite prose fields and nothing else — never code, schema,
options, blocks, the tagged concept, the kind, or any field carrying the
planted defect — and it is told not to change the task or the pitch. A
creative second pass would be a second generator, with a second set of
failures nothing checks.

**Each kind states its own task**, so the judge measures a giveaway against
something concrete rather than a general idea of fairness:
`ExerciseSection.judge_task` is the one-sentence task (abstract on the base
class, so a new kind fails loudly rather than shipping unjudged),
`.discovery?` marks the kinds whose task is to find something hidden
(`code_review`, `design_comparison`, `security_review`, `plan_review`,
`parsons_problem`), and
`.prose_fields` bounds what may be rewritten. A kind whose task is to name
the concept is not rejected for naming it: the prompt says so outright, and
"What vulnerability exists in this endpoint?" is the intended framing for a
security review.

**Every deterministic check lives at the boundary, in `JudgeVerdict`.**
`STATUSES`, `ISSUE_TYPES` and `PRINCIPLES` are closed lists;
`.parse` refuses a status, issue type or principle outside them, a rewritten
field that is not one of the kind's `prose_fields`, a field rewritten to
blank, and evidence or a rejection reason that is missing, blank or not a
string. Evidence is not matched against the section's text: nothing acts on
it, and a verdict refused over a paraphrased or elided quote falls back to
the draft, so a real rejection would ship the broken section it caught. It
is there for a person reading the log. `#apply` merges the rewrite
over the section, leaving the artifact untouched. Because the code checks
all of that, the prompt states only the semantic judgments — the same split
`ProblemSetIngest` applies to a problem set.

**Concept history is deliberately not passed.** The judge sees one section,
its concept, its rung and lock state, and the kind's task; no other section,
no rationale, no history. That severs the channels a tier could leak
through, and it costs something real: the judge cannot know what this user
has met, so "unstated prerequisite" is judged against the rung's
`KindDifficulty::LEVEL_DEFINITIONS` sentence rather than against the person.
The app records nothing about incidental knowledge anyway — whether someone
knows what a Thread is was never tracked — so there is no history that would
have answered it.

**A rejection buys a bounded number of retries, never an open-ended
loop.** The count is a plan fact, `DailyPlan::Result#judge_retries`: 2
(`DailyPlan::DAILY_JUDGE_RETRIES`) for one of the plan's daily kinds, since
every day is built around them, and 1 (`ROTATED_JUDGE_RETRIES`) for every
other kind. It was a kind facet until the daily kinds became a per-user
value (`docs/decisions/daily-kinds.md`). `retry_section` regenerates
that kind alone through the same renderer and the same ingest —
`GenerationPrompt#render`'s `only:` restricts the kinds and the schema,
`fixed_concept:` adds the line naming the concept the section must carry,
and `ProblemSetIngest`'s `fixed_concepts:` enforces it through
`enforce_fixed_concepts!` at the boundary. The concept is fixed because the
plan placed it: a retry free to choose again could drop a due retention
check. Each retry is judged again. Rejecting the last retry, or a retry
generation that fails for any reason (`[judge_retry_failed]`), drops the
section. The outcome's `retry_principle`, `retry_issues`, `retry_evidence`
and `retry_reason` are lists with one entry per judged retry, in order.

**A drop removes the key after ingest**, so no placeholder exists and every
downstream count still derives from `active_section_keys`. The dropped keys
persist on `daily_exercises.dropped_sections` (jsonb), and the dashboard
says so in one muted line (`dashboard.section_left_out`), which is the only
user-facing change. Every kind can be dropped, both daily kinds included:
with two of them, a day without one is still a day. A day whose sections
are all dropped raises `AiService::AllSectionsRejectedError`, which
`GenerateDailyExercisesJob` records through `persist_failure` like any
other failed generation, so no empty day is ever written. Before both
fixed kinds existed, a twice-rejected `code_review` shipped with
`fallback: anchor` and an `anchored: true` stamp. Older rows keep it, and
nothing writes or reads it, so it is no longer a server stamp.

**The rotation trade is stated rather than compensated for.** A dropped
section still reads as scheduled: `User#recent_exercise_history` puts the
dropped keys back into `section_keys`, so `SectionRotation` sees the kind as
shown and its staleness does not grow from a delivery failure.
`ExerciseHistoryEntry#dropped` is added to the answered count in
`SectionCount`'s mean, but a day's credit never exceeds the sections it
delivered (`active_section_keys`), so a drop cannot count as finishing
sections the engineer never saw. That cap means a drop can still shorten
tomorrow: three planned four-section days that each delivered two sections
contribute at most two apiece, so the next day gets at most three sections.
Within the cap, a drop fills in unanswered delivered sections, so on a day
that lost one section, answering two of the three delivered counts the same
as answering all three (#215). A day with nothing answered still earns
zero, so a drop never turns an untouched day into finished work. This
reverses the rule #215 shipped, which credited a drop only when every
delivered section was answered: with two fixed kinds that can each be
dropped, that rule let one rejected section shorten tomorrow. The cost of the rotation trade is the reverse
of the loop it prevents: a kind the judge keeps rejecting can go unseen for
a long time without the starvation guarantee noticing. Nothing in the
rotation compensates, on purpose. The one exception is a two-section
Automatic day, where the coverage exception reads delivered dates and so
may add such a kind back, at most once in five weekdays. Drop rate per kind is read off the
`[difficulty_diagnostics]` line's `judge:` entries, which are keyed by
section key and carry `dropped: true`; rejection rate per principle comes
off `principle` and the `retry_principle` list in the same entries, each
with the `evidence` the judge quoted and the `reason` it gave, so a rate
can be read back against the text it was about. A design comparison's
entries carry no evidence or reason, for the reason `design-comparison-the-second-fixed-section.md` gives. That drop rate is
the thing to watch, and `pattern` is the likely candidate, since its task is
the least stated in the generation prompt.

**Planned concepts a drop left unhosted are recorded and nothing is
rescheduled.** The plan attributes a concept to a section only in the fourth
slot, so `unhosted_concepts` decides after the fact the way `log_retention`
already decides honored: the dropped section's own concept, matched against
what the plan offered as a due check or as reinforcement. It can therefore
never name a concept the plan did not offer. The `[retention]` line gains
`dropped=key:concept`, so a due check tagged on a dropped section reads as
offered rather than honored, and the diagnostics payload gains `unhosted:`.
Each of the two `[retention]` lines names only its own track's drops: a
dropped fourth-slot kind (`ExerciseSection.fourths`) goes on the fourth
bucket's line, and every other dropped kind on the language line.

**A judge failure never costs the day its set.** When `judge_section`
raises, times out, or returns output `JudgeVerdict` refuses, the draft
section stands unedited, `fallback` records the reason from
`AiService.judge_fallback_reason` (`invalid_output`, `truncated`,
`invalid_json`, `refusal`, `timeout`, `deadline` when a regeneration's
deadline left no time to start the call, the shared error code, or
`http_<status>` when the provider refused the request itself), and
`[judge_fallback]` warns. Provider errors carry the response's HTTP status
(`AiService::Error#http_status`); authentication and rate-limit errors keep
their own codes. The judge is never retried. The review prose
judge reads the same table, so the two judges' fallback rates compare.

**The judge's reply is held to a schema on Claude.** Its call is capped, so
it runs with thinking off, and with nowhere else to reason the model once
wrote its checks out as prose and never reached the JSON. `judge_section`
passes `JudgeVerdict.schema_for(kind)` as `response_schema:`, and
`ClaudeService` sends it as structured output (`output_config.format`), so
the API only lets the model return one of the three verdict shapes. A
prefilled `{` was the other option; every model `ClaudeService` routes to
rejects a prefill with a 400. The schema is built from the same closed
lists `.parse` checks, and `.parse` stays the boundary, since the schema
cannot bound string length. `GeminiService` sends the same schema as the
Interactions API's `response_format` (`type: "text"`, `mime_type:
"application/json"`) (#228). Gemini documents only part of JSON Schema, and
the verdict schemas use `anyOf`, `const` and `additionalProperties: false`;
a schema Gemini refuses fails the call, which falls back to the draft like
any judge failure. `script/check_gemini_structured_output.rb` sends judge
fixtures on the production route to confirm Gemini accepts them.
`OpenaiService` answers a request's `response_schema` with JSON mode (`text.format:
json_object`) rather than the schema: OpenAI's strict schemas need an object
at the root and every property required, and `VerdictSchema` builds an
`anyOf` with optional fields. JSON mode guarantees a parseable reply, and
`.parse` holds the shape. OpenAI refuses JSON mode with a 400 unless an
input message mentions JSON, and the system prompt goes in `instructions`,
which it does not check, so `OpenaiService` ends the input with
`JSON_MODE_REQUEST`. Before that, only a section whose own text happened to
mention JSON was judged on OpenAI (#253).
`response_schema:` and `single_attempt:` began as optional keywords on
`#call`, added one at a time like `cache_system:`, `max_tokens:` and
`history:` before them. They are now fields of `AiService::Request`.
`judge_section` and `judge_review_prose` (`ReviewProseVerdict.schema`) pass
a schema to `AiService.request_for` per call, and every other caller leaves
it nil; the `judge_review` row of `AiService::CALL_PROFILES` sets
`single_attempt`, and no other profile does. The additive-keyword pattern
was replaced because each new keyword meant editing five `app/` files and
every spec that overrode `#call`, while the settings are facts about a purpose.
`spec/services/provider_request_characterization_spec.rb` records the body
each purpose's request sends to each provider and fails on any changed
byte, which holds every caller that passes no schema byte-identical.

**Known leak, reported and left.** The reference disclosure above a section
is titled "Reference — <concept>: how it works", which on a discovery kind
names what to find before the engineer looks. It is the same leak the judge
is told never to flag, because the label already exists outside the section.
Fixing it means a neutral summary until the section is answered, which is a
change to the reference, not to generation.

**Cost and latency are estimates.** Against an Opus 5.5 draft and a Sonnet 5
judge on a four-section day, the draft is roughly $0.15-0.23; judging adds
about $0.03, and one retry with its re-judge about $0.07 more — under a
fifth of a normal day, and Haiku would halve the judge's share. Worst case
runs about 55-155 seconds on top of the draft for one retry cycle (judge
fan-out 5-15s, retry 15-40s, re-judge 5-10s), plus about 20-50 seconds and
$0.07 when a daily kind needs its second retry, and stays there however
many sections were rejected: the retries fan out the same way the judging
does, so the day waits for the slowest rather than their sum.
`JUDGED_GENERATION_BUDGET`, which the dashboard's generating poll reads,
derives its retry cycles from the larger of the two retry counts, each
cycle `worst_case_call_seconds(RETRY_READ_TIMEOUT)` plus
`worst_case_call_seconds(READ_TIMEOUT)`, plus one judge call when a kind
re-judges its edits. Each retry asks for one
section, so it runs on `RETRY_READ_TIMEOUT` rather than the draft's
300-second budget. Both figures assume that token
shape and that list price; re-measure against `ApiUsage` rows under
`purpose: "judge_section"` rather than re-deriving them.

**Stage 1 never carried `PLAIN_LANGUAGE_STANDARD`.** The standard is
interpolated into the duck, alternates, follow-up, grading, concept
reference and recognition guide prompts, and into neither `build_system_prompt` nor
`GenerationPrompt#render`. `JUDGE_SYSTEM_PROMPT` does carry it, which is the
point: the judge rewrites prose, so the standard sits where the rewriting
happens. So nothing was removed from the draft prompt to
make room for the judge: the field bounds it does carry define the artifact
or are enforced by ingest, and they stay. Prose quality is the judge's job
by assignment, not by subtraction.

**The judge is shown the section, not how it was made.** `judge_section`
strips the answer key and every `ProblemSetIngest::SERVER_STAMPS` field, so
it never learns the day eased this section, which real file grounded it, or
that an earlier verdict rejected it. `current_schema` is deliberately not
stripped: it is on the engineer's screen, and answerability depends on it.
The rung and lock state reach the judge as stated arguments instead, since
a level is what it measures against. `JUDGE_SYSTEM_PROMPT` enumerates the
rejection principles and issue types from `JudgeVerdict`'s own constants
rather than restating them, so the prompt cannot offer a verdict the
boundary would refuse.
