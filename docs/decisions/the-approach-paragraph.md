# The approach paragraph

Decided 2026-11-03. A trial behind a switch that is off by default.

When the switch is on, each section's feedback writes `next_step` as a short paragraph. It says how an experienced engineer would start on this kind of problem and where the answer did or didn't follow that start, then names one thing to study. A walkthrough of an unanswered section leaves out the part about the answer.

## Decisions

- **It reuses `next_step`.** `DailyResponse::AI_REVIEW_FIELDS` gains no entry, and `ai_review` gains no key, so the page, the email, the prose judge and the follow-up prompt carry the paragraph with no change. The cost is one field holding two ideas, the approach and the study step. A separate `approach` field would be cleaner, but it would add a stored key, which this change rules out.
- **The label is "Approach and next step"**, the value of `review.fields.next_step`. It follows the locale, not the switch. With the switch off, a one-sentence next step shows under it, and the follow-up prompt's summary line says "Approach and next step:". That was accepted.
- **The switch is `REVIEW_APPROACH_PARAGRAPH`**, on only when its value is exactly `"1"` (`ReviewApproachParagraph.enabled?`). `AiService#build_review_section_prompt` reads it and hands `ReviewPrompt` a plain `approach:` value. With it unset, the review prompt is byte for byte what it was before the switch existed, and a spec holds that against the recorded snapshots.
- **The grader writes the paragraph from what it already sees.** It never draws on `SectionKindGuide`, which doesn't reach a provider prompt. A per-kind hint would be new per-kind text, so there is none.
- **Unchanged**: the prose judge's prompt and route, so its activation gate isn't triggered, and `RUBRIC_VERSION`, since a rating means what it did.
- **Railway**: only the web service grades, so only it needs the variable. Setting or unsetting it is the owner's call, asked each time.

## Isolation

The grader sees what it saw before: the problem, the answer, the self-rating, the pitched-at rung and the grading note, plus the answer keys of an ambiguity hunt and a design comparison, as it always did. Grading never runs before submission, because `ResponseReview` returns `:not_submitted` before any call. The paragraph renders only where `next_step` does, on a submitted review. Generation, the duck and the section judge don't read review prose, and no log line carries it: the grade reply is parsed with `log_raw: false`.

## Expected cost

On Claude Sonnet 5.5 at effort high, it adds about $0.002 to $0.007 per graded section, and $0.005 to $0.03 a day. That's an estimate, not a measurement. The Account page's Claude cost shows the real figure over the trial.

## Trial checklist

For each paragraph written during the trial:

- **Specific**: it's about this problem, not advice that would fit any problem of the kind.
- **Correct**: the how-to-start advice is right for this problem.
- **Not repeated**: the same advice doesn't come back, near word for word, on other days.
- **Judge**: note whether the prose judge shortened it. Compare the stored `next_step` with the original kept for audit (`ReviewProseVerdict::ORIGINAL_KEY`).
- **Parsons and pattern**: it reads sensibly on a Parsons problem, whose rating is fixed and whose answer is an order of blocks, and on a pattern section.

## Stop rule

Count the first 10 paragraphs the trial writes. If more than 2 of them are generic or wrong, by the first two checklist items, either tighten the `next_step` line in `ReviewPrompt` or turn the switch off.
