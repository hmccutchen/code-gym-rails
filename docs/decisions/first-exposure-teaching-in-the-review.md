# The concept's short version in the review

A review tells an engineer what they missed in their answer, but not what
the concept is. On a concept's first exposure, or when the answer missed the
main point or an essential piece, a short version of the concept next to the
review is the cheapest help. Its text is already written and stored in
`ConceptReference`, so showing it costs no provider call.

This replaces `docs/first-exposure-teaching-spec-2026-10-27.md` as the
reference.

## When it is offered

`ReviewShortVersion#offered?(section)` is the one rule. A reviewed section
offers the short version when its concept is tagged and isn't `"other"`, and
either:

- **First exposure.** `ConceptExposureIndex#count_for` returns 1 on the
  response's date. After submit, the count includes the day itself, so 1
  means no earlier submitted day carried the concept. The dashboard's
  `first_exposure?` runs before submit and tests `.zero?`.
- **A low grade.** `DailyResponse#ai_rating_unfavorable?` is true:
  `beginner` or `developing`.

It also needs a `ConceptReference` row for the concept. The partial checks
that, not the model: sections that share a concept share its row, so a
missing row can't change which section offers it.

**The cases this settles:**
- **A skipped section** has no rating, so only first exposure offers it.
  `ConceptExposureIndex` counts a skipped section of a submitted day as an
  exposure, since it was shown. A skipped section on a later exposure gets
  nothing more, because the walkthrough already teaches.
- **Two sections, one concept, one day.** The first section in
  `active_section_keys` order that qualifies offers it, and no other section
  with that concept does, so the page never shows the same text twice. A
  section that doesn't qualify never takes the place: with a `solid`
  section on a later exposure ahead of a `developing` one, the `developing`
  one offers it.
- **A Parsons section.** Its rating is fixed in Ruby, but it is still the
  section's rating, so it follows the same rule.
- **Old rows.** Nothing is stored, so History offers it on past days too,
  judged on that day's date.

## It never reads the mastery tier

The rule reads the exposure count and the section's own rating and review,
which the review already shows. It never reads `ConceptMastery`, its tier,
drills or reinforcement, so the offer can't imply a tier.
`spec/conventions/review_short_version_tier_spec.rb` fails if the model or
the partial names `ConceptMastery`.

## One exposure count and one reader of the graded review

Decided by the owner after the plan review, on 2026-10-27.

- **The exposure count** lives on `ConceptExposureIndex`, which owns which
  tags count (`.counted?`) and which bucket a section records under
  (`.key_for`). `DailyResponse#improved_code_visible?`, the first-exposure
  helper and `ReviewShortVersion` all read it, and nothing else restates the
  key. `ReviewShortVersion` is handed the index, so its specs need no
  database.
- **The review as graded.** `ReviewProseVerdict.as_graded` puts the
  grader's own fields back over the prose judge's rewording. Every reader
  of `graded_prose` goes through it (#592).

## What it shows

From the section's reference row, in this order:
1. `tagline`, bold.
2. `guide_plain_language` when the row has a guide (`ConceptReference#guide?`).
3. The worked example through `learn/_worked_example`.
4. `guide_pitfalls`, only with an essential gap (below).

A row without a guide shows `explanation` and `code_example` in place of 2
and 3. The senior lens, the ladder and the lesson stay on the Learn page,
and the block links there ("More on this concept").

## Pitfalls only with an essential gap

`guide_pitfalls` is one block of prose, not a list, and the review has no
structured missing step yet, so no code can tell which pitfall a miss
matches. Pitfalls show only where something essential was missed.

`ReviewShortVersion#essential_gap?` is true when the section has a rating
and either:
- the rating is `beginner` or `developing`, which by the rubric means an
  essential gap, or
- `RubricCheck#essential_gaps`, read from the review as graded, is
  non-empty.

A `developing` review with an empty gap list counts, because the rating the
review shows says so. A skipped section never shows pitfalls.

Matching a pitfall to the missing step waits until the grader names the
missing step. Matching text in Ruby is rejected: word overlap between a
provider's miss and a provider's pitfall is a guess that looks like a rule.

## Where it sits and how it looks

Inside the section's `review-block` in `shared/_ai_review`, after the review
fields and before `improved_code`. On a first exposure the improved code is
hidden, so the short version stands where the fix would be. On a later
exposure with a low grade both show, the short version first and closed.

**Both disclosures stay.** The section on the submitted dashboard keeps its
own closed reference by the problem, and the review gets the short version
by the feedback. On History the section disclosures sit inside the collapsed
problems block, so the review's copy is the one in view.

**Closed by default, always,** with no exception for first exposure. It is a
`<details class="ref review-short-version">` whose `<summary>` reads "Show
the short version". It reuses the `.ref` styles and chevron and adds no
inline style. Closed, it takes one line at 360 pixels, which
`spec/system/review_short_version_spec.rb` measures. The summary holds no
glossary terms, since a term is a control and can't sit inside the summary
control.

**Glossary terms** are underlined through `glossary_wrap` and
`glossary_wrap_prose` with one `seen` set for the whole block, so a term is
underlined once in it.

**The review email leaves it out.** The email is plain text and already
long, so the short version is a reason to read the review on the site.

## Guide coverage when it was built

Before any code, a read-only production count found that all 4 concepts the
owner had seen had a guide. The rule was to stop if fewer than about half
did, since the short version would then mostly repeat the section's own
disclosure.
