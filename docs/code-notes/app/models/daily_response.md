# app/models/daily_response.rb

## `MAX_ALTERNATES_PER_SECTION`

The cap is enforced on the server as well as in the view. Hiding the button does not stop a crafted request.

## `AI_REVIEW_FIELDS`

`shared/_ai_review` and `ReviewMailer` both read this list. `next_step` is not a list field because it is meant to name one thing to study.

## `.ai_review_label`

A prompt passes `locale: :en`, so text sent to a provider never follows the request's locale.

## `.self_rating_labels`

The labels are read at render time, so the request's locale chooses the wording.

## `.answered_kinds_for`

The kinds a user has answered on a submitted day, read from `section_ratings`
keys. Submitting slices the ratings to `answered_sections`, and the submit
gate requires every answered section to be rated, so on a submitted row the
rating keys are exactly the answered sections. That reads the answered
authority back without loading each exercise. Rows submitted before the slice
(commit `76a7d5e`, 2026-10-10) can still carry a rating on a skipped section,
which makes that kind count as answered early. The only reader is the answer
form's "About" disclosure, which then hides a little sooner; that cost is
accepted. The union runs in SQL, so the read returns at most one row per kind
however many days have been submitted.

A change to the rating slice in `ResponsesController#assign_draft_response`
(`section_ratings.slice(*@response.answered_sections)`) changes what this
method means, so check this reader with it.

## `.review_points`

Older reviews stored a single string instead of a list, so a non-array value is wrapped. This is a class method because mailer views don't include helpers.

## `REVIEW_CLAIM_STALE_AFTER`

The value is a literal rather than derived from the review chain's timeouts, because deriving it would couple load order between this model and `AiService`. `ai_service_spec` checks that it outlasts the longest review chain.

## `#replace_blocker`

What stops start over and regeneration from destroying this response. A
stored review has already moved `ConceptMastery`, which nothing can undo. A
fresh review claim blocks too, since `#review` holds no lock during the
provider call. A stale claim does not block, because the claim is treated as
abandoned. Its provider call may still be running; if it finishes, it finds
the claim gone and writes nothing (`ResponsesController#store_review`).

## `#merge_pseudocode_round!`

Nil values are dropped from the merged round. That lets a caller clear a claim in the same merge that records its result.

## `#pseudocode_claimed?`

It reuses `REVIEW_CLAIM_STALE_AFTER` on purpose: both checks ask whether a paid provider call may still be running.

## `#completeness`

The zero guard matters: a payload with no Hash sections has no section keys, and dividing by zero gives NaN, which `#round` raises on.

## `#improved_code_visible?`

Improved code is revealed only from a concept's second exposure onward. A section tagged blank or `"other"` is not gated.
