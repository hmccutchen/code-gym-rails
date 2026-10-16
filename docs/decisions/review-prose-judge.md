# Review prose judge

an optional second pass over each graded review,
for readability only. `AiService#judge_review_prose` reads the review as the
page renders it (`ReviewProseVerdict.project`) and may reword its prose
fields for plain language or length; it is never shown the answer, the
problem or the grading note, so it has nothing to regrade from. The
signature is the guarantee, as with `#assess_difficulty`. Verdicts are
`keep` or `edit`, with issue types `plain_language_violation` and
`verbosity`.

**What is mechanical.** `ReviewProseVerdict.parse` is the boundary. It
refuses a status or issue type outside the closed lists, a rewrite of any
field that is not one of `DailyResponse::AI_REVIEW_FIELDS`, a blank rewrite,
and a list field that does not cite every original entry exactly once, in
order, at its earliest source's position; a merge of entries needs a
`verbosity` issue. A rewrite of a field that was empty is dropped rather
than refused: it has nothing to cite, so it can only be invented, and
refusing would also discard a sound rewrite of another field. An edit left
with nothing after that reads as `keep`. Grade, rating and every other
field are protected because only the prose fields can be named. On a `keep` or a fallback the
grade is stored as the provider returned it, and `AiService#grade_review` strips any
`graded_prose` key the provider sent, since `graded_prose` is server-owned:
an edit stores the grader's original prose there, exactly as returned, as
the audit record.

**The accepted risk is claim preservation.** Citation proves no point was
dropped or duplicated; it cannot prove a rewrite still says the same thing.
A negation, a condition or an identifier could change and nothing checks it.
That is why the judge shipped off, and why turning it on took a person
reading rewrites rather than a check passing — see the activation gate
below for the bar that was set.

**Placement and failure.** `ReviewGrading#judged_review` runs inside each
section's grading thread, after grading and the Parsons rating override, and
has its own rescue. It rescues `StandardError`, not just `AiService::Error`,
because `Thread#value` re-raises whatever `ReviewGrading#grade_section`'s narrower rescue
misses, and no judge failure may cost the engineer the review. A failure
returns the grade unchanged and logs `[review_judge_fallback]` with a fixed
reason code from `AiService.judge_fallback_reason`, the table the section
judge also reads, never the error message, which can carry provider text. The call is billed as `judge_review`, which is in
`ApiUsage::PURPOSES`, and capped by `REVIEW_JUDGE_MAX_TOKENS` (1,500). The
cap was re-checked against the comparison script on 2026-10-09; the run
record at the end of this doc has the measured figures.

**One attempt, and a 12-minute claim.** The call passes `single_attempt:
true`, which refuses every retry, status retries included, and runs on
`REVIEW_JUDGE_READ_TIMEOUT`. The grading stage's time budget now includes
that one call (`OPEN_TIMEOUT + REVIEW_JUDGE_READ_TIMEOUT`), so
`DailyResponse::REVIEW_CLAIM_STALE_AFTER` is 12 minutes, whether or not the
switch is on. A claim window shorter than the chain would let a second
review start while the first is still running.

**Claude only.** `AiService.judges_review_prose?` is false on the base class
and true on `ClaudeService` (and `FakeService`, for specs). The judge relies
on structured output, and the comparison script that gates the switch runs
only Claude models. `GeminiService` sends structured output now (#228), but
nothing has compared rewrites on its route, so a Gemini user is never
judged. Neither is an OpenAI user, whose JSON mode does not hold the reply
to the schema.

**Logging.** The `[review_judge]` line records status, issue types, merge
indexes and timing, never review text, and the reply is parsed with
`log_raw: false`. Transport-level raw-response logging in the provider
subclass may still record the text; that path is not the judge's.

**The switch and the activation gate.** `ReviewProseJudge.enabled?` is true
only when `REVIEW_PROSE_JUDGE` is exactly `"1"`. It shipped off and was
turned on on 2026-10-10. The gate it passed, which any later change to the
judge's prompt or route has to pass again: run both `review_prose` modes of
`script/compare_models.rb` (`review_prose` on stored days and
`review_prose_fixtures`), read every rewrite beside its sources, and
confirm every claim survived. Surviving does not mean word for word: a
rewrite may tighten how sure a vague claim sounds, which the 2026-10-10
decision below accepted and bounded. What fails is adding or dropping a
point, reversing a negation, changing a condition or an identifier,
dropping a next-step topic, and losing a qualifier that carries a real
limit — the difference being whether the hedge was filler or was doing
work. Check the measured output tokens
against `REVIEW_JUDGE_MAX_TOKENS` at the same time, and the slowest
measured calls against `REVIEW_JUDGE_READ_TIMEOUT` (30 seconds): the call
has one attempt, so a timeout is billed and then falls back.

**Both modes ran on 2026-10-09, and that run left the switch off.** On
`claude-sonnet-5-5`, `review_prose_fixtures` hit the expected status on
8 of 8 with 0 invalid replies, producing 6 edits and 1 merge; `review_prose`
over 4 stored reviews kept every one unedited, which is what stored
reviews that are already plain should do, so the fixtures carry the
signal. Haiku is not a candidate here: it hit 6 of 8 and returned 2
invalid replies, both refused by the cite-every-entry rule, and in one
case added a claim that was not in the source.

The two budget checks pass with room. The largest reply was **347 output
tokens of the 1,500-token `REVIEW_JUDGE_MAX_TOKENS`**, and the slowest
call **3,099 ms of the 30,000 ms `REVIEW_JUDGE_READ_TIMEOUT`**, so the cap
that came from a four-review sample is not tight.

Every Sonnet rewrite was read beside its source; no negation, condition or
identifier changed. Two did change a claim, which is what the gate asks
about: `string_fields` sharpened "essentially a performance thing" to
"slows the page down", stating more than the source did, and
`verbose_jargon` compressed a four-topic next step to "Study ActiveRecord
preloading", dropping three topics. Both change what the engineer is told
to do next, so **the gate is not met and the switch stays off.** Turning it
on needs the prompt or the boundary changed so those two shapes stop
happening, and both modes read again. Accepting them instead would be a
change to the gate itself, which is a decision to state here rather than a
box this run ticked.

**The prompt asked for both.** Its issue list called "needless hedging" a
plain-language problem and "a next step that names more than one thing to
study" a verbosity one, so the judge was following instructions when it
firmed up a vague claim and cut four topics to one. Both items are gone
from `REVIEW_PROSE_ISSUE_GUIDANCE`. The rules now say to keep how sure each
claim is and every topic a next step names, and a spec holds the prompt
to that. The grader still asks for one topic per next step; when it names
several, the judge keeps them all, because choosing which to drop changes
what the review says.

**Both modes ran again on 2026-10-10, against the corrected prompt. One
shape is fixed, the other is not, and the remaining one was accepted — the
switch is on.**
`review_prose_fixtures` was run twice on `claude-sonnet-5-5` to tell a
reliable shape from a stochastic one. Both runs hit the expected status on
8 of 8 with 0 invalid replies, 6 edits and 1 merge; `review_prose` over 4
stored reviews kept every one unedited again. Haiku is still not a
candidate: it returned 1 invalid reply of 8 on the fixtures and 2 of 4 on
the stored reviews.

The next-step shape is fixed. `verbose_jargon`'s four topics survived both
runs ("preloading, association loading, query optimization, and database
performance tuning"), and the hedges survived with them: "might arguably
be issuing … may potentially impact" became "might be issuing … may slow
things down", which keeps both limiting words.

The certainty shape is not fixed, and it resists the prompt.
`string_fields`' "which is essentially a performance thing" became "which
slows the page" on the first run and "which slows the page down" on the
second — the same claim change the 2026-10-09 run refused, reproduced twice
against a rule that forbids it in as many words. The rule's own example was
rewritten in `67c8fa93` and no longer contains that phrasing, so the model
is not echoing the prompt; it reaches for the sharper sentence on its own.
Two rounds of prompt wording have now failed to hold this one, which is
evidence about what a prompt can bound rather than a wording still to be
found. The mechanical boundary cannot take over, and not for the reason it
first looks: `missed` is a list field, so the rewrite did go through
`parse_entries` and did cite its source. The fixture's `missed` is one
sentence, which `review_points` projects to a single entry, so citing it is
the only thing a rewrite of that field can do and the citation rule is
satisfied whatever the sentence now says. This is the accepted risk two
paragraphs up, met in the wild: citation proves no point was dropped or
duplicated, never that a kept one still means the same.

So the gate came down to a bar rather than a fix, and the bar was set on
2026-10-10: **a rewrite may tighten how sure a claim sounds, as long as it
adds, drops and contradicts nothing.** "A performance thing" becoming
"slows the page" says what the same review's `correct` field already says
— "You noticed the page was slow." — so the engineer is told nothing new.
What stays blocking is unchanged: an added or dropped point, a reversed
negation, a changed condition or identifier, a dropped next-step topic.
Hedging that carries a real limit still has to survive, which is what
`verbose_jargon`'s "might … may" case checks; what was accepted is the
vague filler phrase, not the qualifier. The accepted risk two paragraphs
up is the reason this is a judgment and not a check: citation proves no
point was dropped or duplicated, never that a kept one still means the
same, so no boundary can be asked to hold this line.

**The switch went on after that decision**, with `REVIEW_PROSE_JUDGE=1` on
the web service. Reopening the question means reading rewrites again, not
re-running the fixtures: both modes have now been run three times across
two prompts, and the shapes they surface are stable.

The budget checks still pass with room, measured on the corrected prompt:
the largest reply used a fraction of `REVIEW_JUDGE_MAX_TOKENS` and the
slowest call a tenth of `REVIEW_JUDGE_READ_TIMEOUT`.
`REVIEW_JUDGE_MEASURED_MAX_OUTPUT_TOKENS` moves to what this run measured;
that constant and its section in `docs/code-notes/app/services/ai_service.md`
are where the number and its remaining headroom are stated, so they are not
restated here to go stale.
