# Mastery loop: combined self-rating + AI-review signal

## Problem

The mastery loop (reinforcing a concept in future generations until it's
"mastered") currently triggers only off the user's self-rated difficulty
(`DailyResponse#rating`: `too_easy` / `right_level` / `too_hard`, one value
for the whole day). It ignores the AI review's own per-section assessment
(`ai_review[section]["rating"]`: `beginner` / `developing` / `solid` /
`strong`).

A user can genuinely miss the point of a problem — get a "beginner" or
"developing" AI assessment — while self-rating the day "right level," because
they aren't calibrated enough to recognize their own gap. That's exactly the
population most in need of reinforcement, and today they get none, because
the loop only listens to self-report.

## Data model (confirmed, no migration needed)

Both signals already live on `DailyResponse`, keyed by the same section names
(`code_review` / `pattern` / `challenge` / `architecture`):

- `concept_tags[section]` → the concept tagged on that section
- `ai_review[section]["rating"]` → the AI's per-section assessment (nil if
  the response was never reviewed)
- `rating` → the day's single self-rating (nil if the user never used the
  feedback widget)

This is a clean 1:1 lookup: for a concept tagged on a given section in a given
session, `ai_review[section]["rating"]` is that section's AI signal. No new
tracking, no schema change — this is a read/logic change only.

## Combined rule

Applied per concept, resolved on that concept's **single most recent
occurrence** (mirrors the existing self-rating-only loop's "most recent
rating" framing — this is not cumulative; a concept mastered weeks ago does
not resurface because of an old bad day):

```
if self_rating.nil? && ai_rating.nil?
  out_of_scope        # no information at all — same as an "unrated" concept today
elsif self_rating in [right_level, too_easy] && ai_rating in [solid, strong]
  mastered            # both signals explicit and favorable
else
  needs_reinforcement # too_hard, beginner/developing, disagreement in either
                       # direction, or one signal favorable with the other
                       # absent/unconfirmed
end
```

Key implications, stated explicitly (resolved during design, not left
implicit):

- **Either signal being explicitly bad is enough to reinforce** — self
  `too_hard` OR that section's AI rating being `beginner`/`developing`.
- **Mastery requires both signals to explicitly agree** — an absent AI
  review never counts toward mastery, even if self-rating is favorable. A
  section that was never reviewed cannot exit the reinforcement loop on
  self-report alone; this is intentional, not an edge case that happens to
  work out — uncertain data defaults to continued reinforcement.
- **Disagreement always resolves to reinforcement**, not mastery, in either
  direction (self favorable + AI unfavorable, or self unfavorable + AI
  favorable) — the whole point is catching miscalibrated self-assessment.
- **Total absence of both signals** (never rated, never reviewed) is out of
  scope, identical to today's "unrated" concepts — this is the only case
  that doesn't default to reinforcement.

## Implementation shape

### 1. `DailyResponse` — signal predicates (new)

Small single-purpose predicates, matching the existing `submitted?`/
`reviewed?` style, so both the prompt-building logic and the UI transparency
note (below) share one definition of "favorable"/"unfavorable":

- `self_rating_favorable?` → `rating_right_level? || rating_too_easy?`
- `self_rating_unfavorable?` → `rating_too_hard?`
- `ai_rating_for(section)` → `ai_review&.dig(section.to_s, "rating")`
- `ai_rating_favorable?(section)` → `ai_rating_for(section)` in `%w[solid strong]`
- `ai_rating_unfavorable?(section)` → `ai_rating_for(section)` in `%w[beginner developing]`

### 2. `User` — surfacing signals and computing the reinforcement list

- Extract a private `recent_daily_responses(limit)` helper (the existing
  `daily_responses.includes(:daily_exercise).order(date: :desc).limit(limit)`
  query) shared by both public methods below, so they don't issue duplicate
  queries.
- `recent_performance(limit: 10)` — unchanged shape, plus a new
  `section_ratings` key per entry: `{ "code_review" => "developing",
  "pattern" => "solid" }`, built from `ai_review` per section (empty hash
  when unreviewed). This is display data for the prompt's history text —
  item #3 from the original ask.
- New `concepts_needing_reinforcement(limit: 10)` — walks the same window
  most-recent-day-first; for each concept, the first time it's seen (its most
  recent occurrence) resolves reinforce/mastered/out-of-scope via the
  `DailyResponse` predicates and locks that concept's status (later/older
  occurrences of the same concept are ignored). Returns concept names still
  needing reinforcement, most-recent-first. This is the deterministic,
  Ruby-computed half of the hybrid approach.

### 3. `AiService#build_exercise_prompt` — hybrid textual + computed

- **History line** keeps the self-rating visible (do not drop it) and adds
  per-section concept→AI-rating pairs, replacing the old flat, section-less
  concept list:

  ```
  2026-07-15: 3/3 sections answered | self: right level | code_review→n_plus_one (ai: developing), pattern→memoization (ai: solid) | framings: ...; ... | Feedback: "..."
  ```

  A section with no AI review renders as `(unreviewed)` instead of an `ai:`
  value.

- **New explicit line**, computed in Ruby, before the instructions:

  ```
  Concepts needing reinforcement right now: n_plus_one, memoization
  ```

  or `Concepts needing reinforcement right now: none` when the list is
  empty.

- **Mastery-loop instruction bullet rewritten** to reference that computed
  list and state the combined rule in prose, replacing the old
  self-rating-only wording:

  > Mastery loop: reintroduce every concept listed as "needing reinforcement
  > right now" in this set, with a different code example and framing — same
  > underlying concept, never a repeat of the same snippet. A concept only
  > stops needing reinforcement once both signals agree the user is solid:
  > their self-rating was "right level"/"too easy" **and** the AI review
  > rated that section "solid"/"strong". If the two signals disagree, or one
  > is missing (e.g. never reviewed), keep reinforcing — do not treat that as
  > mastery.

- Existing spec assertions hardcoding the old flat `"concepts: n_plus_one"`
  string need updating to the new per-section format as part of this change.

### 4. Transparency note (in scope, not optional)

In `app/views/shared/_ai_review.html.erb` (the single partial rendering
per-section AI review content, already shared by the dashboard's submitted
state and the dedicated `responses#show` review page via
`responses/_submission` — no duplication across views), show a small inline
note for a section if and only if:

```
response.self_rating_favorable? && response.ai_rating_unfavorable?(section)
```

i.e. exactly the favorable-self / unfavorable-AI disagreement this whole fix
targets — not a general "discrepancy" indicator, and not shown for every
AI-rated section. Copy in the app's existing descriptive tone, e.g.:

> You rated this "right level" — the review suggests there's more to work on
> here.

Reuses the same `DailyResponse` predicates as the reinforcement calculation,
so the UI and the personalization logic can't drift out of sync on what
counts as a "disagreement."

## Explicitly out of scope

- Magic-link auth, Resend/SMTP, `/test_login`, timezone work, the
  language-preference spec, `ConceptReference` generation/storage, the
  suggested-concepts admin work, and the architecture section's own
  schema/vocabulary. This fix applies uniformly across all section types
  once architecture ships, but changes none of their individual designs.
- No migration — confirmed above; all data already exists in `ai_review`,
  `concept_tags`, and `rating`.
- No new user-facing surface area beyond the transparency note in the
  section above.

## Testing plan

- `spec/models/daily_response_spec.rb` — new predicates: favorable/
  unfavorable for both self-rating and per-section AI rating, including nil
  safety (no `ai_review`, section missing from `ai_review`, `rating` nil).
- `spec/models/user_spec.rb`:
  - `recent_performance` includes `section_ratings` per entry, nil-safe when
    unreviewed.
  - `concepts_needing_reinforcement` covering: self `too_hard` alone →
    reinforce; AI `beginner`/`developing` alone (self `right_level`) →
    reinforce (the core gap this fix closes); both explicitly favorable →
    excluded (mastered); disagreement in either direction → reinforce;
    unreviewed with favorable self-rating → reinforce (no mastery without AI
    confirmation); both signals absent → excluded (out of scope, like
    unrated today); most-recent-occurrence wins when a concept appears
    across multiple sessions with different outcomes (a concept mastered
    weeks ago must not resurface from old history).
- `spec/services/ai_service_spec.rb`:
  - History line includes per-section `concept→(ai: rating)` pairs and still
    shows the self-rating.
  - Prompt includes the new "Concepts needing reinforcement right now" line,
    both populated and `none`.
  - Rewritten mastery-loop instruction text.
  - Update the existing hardcoded `"concepts: n_plus_one"` assertion to the
    new format.
- `spec/requests/responses_spec.rb` (or dashboard spec, wherever
  `shared/_ai_review` rendering is already covered) — transparency note
  appears only for the favorable-self/unfavorable-AI section, absent for
  agreement or unreviewed sections.
