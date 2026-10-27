# Spec: a short version of the concept in the review (2026-10-27)

Checked against origin/main at `6ecfced`. Not built yet. Once built, its
reasoning moves to `docs/decisions/first-exposure-teaching-in-the-review.md`,
which replaces this spec as the reference; until then this file is the one
to cite, as `docs/stored-answer-keys-spec-2026-10-27.md` section 9 does.

## Decisions

- **Pitfalls** show only when the section has an essential gap (see
  "Pitfalls" below).
- **Both disclosures stay:** the section's own closed reference by the
  problem, and the review's closed short version by the feedback.

## Why

A review tells an engineer what they missed in their answer, but not what
the concept is. On a concept's first exposure, or when the answer missed
the main point or an essential piece, a short version of the concept next to
the review is the cheapest help: its text is already written, stored in
`ConceptReference`, and costs no provider call to show.

## When it is offered

A reviewed section offers the short version when its concept is tagged, isn't
`"other"`, has a `ConceptReference` row, and either:

- **First exposure:** `user.concept_exposures.count(concept, bucket,
  on_or_before: response.date) == 1`, where `bucket` is
  `ConceptBucket.for(section, language)`. On the submitted day that count
  includes the day itself, so 1 means no earlier submitted day carried the
  concept. The dashboard's `first_exposure?` helper tests `.zero?` because
  it runs before submit. The two tests sit next to each other in the code,
  and the difference is why.
- **A low grade:** `DailyResponse#ai_rating_for(section)` is `beginner` or
  `developing` (`DailyResponse::AI_RATING_UNFAVORABLE`).

One predicate states this, `DailyResponse#short_version_offered?(section)`,
next to `#improved_code_visible?`. Both read the same exposure count, so the
bucket lookup moves into one private method they share, and the comment
that now guards `improved_code_visible?`'s key format guards that method
instead.

### It never reads the mastery tier

The predicate reads the exposure count and this section's own rating, which
the review already shows. It never reads `ConceptMastery`, its tier, drills
or reinforcement state, so the offer can't imply a tier. A spec scans the
predicate's source and the partial for `ConceptMastery` and fails if either
names it, in the style of `spec/conventions/app_source_spec.rb`.

### Cases the predicate settles

- **A skipped section.** It has no rating, so only first exposure can offer
  it. `ConceptExposureIndex` counts a skipped section of a submitted day as
  an exposure (it was shown), so a skipped first exposure gets the short
  version under "What a good answer covers". A skipped section on a later
  exposure doesn't; the walkthrough already teaches.
- **Two sections, one concept, one day.** Common on a shared-concept day.
  The first section in `active_section_keys` order that qualifies offers
  it, and no other section with that concept does, so the page never shows
  the same text twice. A section that doesn't qualify never takes the place:
  with a `solid` section on a later exposure ahead of a `developing` one,
  the `developing` one offers it. On a first exposure both qualify, so the
  first one offers it.
- **A Parsons section.** Its rating is fixed in Ruby, but it is still the
  section's rating, so it follows the same rule.
- **Old rows.** Nothing is stored, so history pages for past days get the
  offer too, judged on the date of that day.

## What it shows

Built from the reference row the section's dashboard disclosure already
loads (`ConceptReferencesHelper#concept_reference_for(concept, bucket)`, memoized
per request), in this order:

1. `tagline`, bold.
2. `guide_plain_language` when the row has a guide (`ConceptReference#guide?`),
   else `explanation`.
3. The worked example: `guide_worked_example` through
   `learn/_worked_example` (highlighted code, prose through
   `glossary_wrap_prose`) when the row has a guide, else `code_example`
   through `highlighted_code`.
4. `guide_pitfalls`, under the rule below.

`senior_lens`, the ladder and the lesson stay on the Learn page; the short
version links there ("More on this concept", to `learn_concept_path(bucket, concept)`)
for anyone who wants the rest.

### Pitfalls

Decided: pitfalls show only when the section has an essential gap.
`guide_pitfalls` is one block of prose, not a list, and the review has no
structured missing step yet, so no code can tell which pitfall a miss
matches. Limiting them to sections with an essential gap shows them only
where something essential was missed.

A section has an essential gap when it was graded (it has a rating; a
skipped section never shows pitfalls) and either:

- its stored `essential_gaps` is non-empty. When the prose judge reworded
  the review, the positions live in `graded_prose`
  (`ReviewProseVerdict::ORIGINAL_KEY`) beside the list they number, so the
  check reads them there first, as `ReviewGrading#gaps_beside_their_prose`
  stores them; or
- no gaps were stored (a Parsons section, whose rating Ruby fixes, or a
  review whose gap positions the grader returned unreadably) and the rating
  is `beginner` or `developing`, which by the rubric means an essential gap.

A `developing` section whose stored `essential_gaps` is empty is the
rubric check's disagreement case (`RubricCheck#agrees?` is false). It counts
as having a gap, because the rating the review shows says so.

Matching a pitfall to the missing step waits for the route fields: the
grader names the missing step, and a later change asks it which pitfall, if
any, that step is. That needs the pitfalls in the grading prompt, which the
isolation rules allow (they cover `SectionKindGuide` and
`ConceptBookSources`, not the reference), but it is a prompt change with
its own measurement. Matching text in Ruby is rejected: word overlap between
a provider's miss and a provider's pitfall is a guess that looks like a
rule.

## Where it sits in the review

Inside the section's `review-block` in `shared/_ai_review`, after the review
fields and before `improved_code`:

- **First exposure:** `improved_code` is hidden (`#improved_code_visible?`
  needs a second exposure), so the short version stands where the fix
  would be. The concept comes first, and the corrected code comes once
  they have seen it twice.
- **Later exposure, low grade:** both show, the short version first and
  collapsed, so the improved code is still the next thing in view.
- **Kinds with no improved code** (`architecture`, `design_comparison`,
  `ambiguity_hunt`, `parsons_problem`): nothing to sit beside; same
  position.
- **The walkthrough:** the short version comes after "What a good answer
  covers" and the other walkthrough fields.

The section on the submitted dashboard keeps its own closed reference
disclosure (tagline, explanation, code example, senior lens), decided above.
The two overlap on the tagline and, for a row with no guide, the explanation
and code. The dashboard one is the full reference beside the problem; the
review one is the short version beside the feedback, and both are closed.
On `/history` the section disclosures sit inside the collapsed "problems"
block, so there the review's copy is the one in view.

The review email (`review_mailer/send_review.text.erb`) leaves it out: it
is plain text and already long, and it carries no link to the page today,
so the short version is a reason to read the review on the site.

## Phone layout

Closed by default, always, with no exception for first exposure: a
`<details class="ref review-short-version">` whose `<summary>` reads "Show
the short version" (a new `review.short_version` key in
`config/locales/en.yml`, the review area's copy). Closed, it adds one line
per offering section. The summary carries no glossary terms, since a term is
a control and can't sit inside the summary control, and it stays a plain
`<summary>`, never `role="button"`.

It reuses the `.ref` disclosure styles and chevron, so
`disclosure_chevron_spec` and the page stylesheet specs cover it, and adds
no inline `style=` (the review partial has two today; this adds none). Open
state isn't saved, matching how section folding works.

## Glossary terms

Terms in its text are underlined through `glossary_wrap` and
`glossary_wrap_prose` like the rest of the review, with one `seen` set for
the whole short version, so a term is underlined once in it rather than
once per paragraph. The glossary controller is mounted on the layout's
`<body>` (`data-controller="glossary code-lines mermaid"`), so terms inside a
disclosure opened after page load work with no extra wiring. Text is
escaped like everything `glossary_wrap` returns; a spec feeds markup through
a reference field and checks it renders escaped.

## Specs and snapshots it touches

- `spec/models/daily_response_spec.rb`: `#short_version_offered?` for first
  exposure, second exposure, low grade on a later exposure, solid on a later
  exposure, skipped first and later exposures, and a blank or `"other"` tag.
  Two sections sharing a concept: on a first exposure only the first
  offers it; on a later exposure with a `solid` section ahead of a
  `developing` one, only the `developing` one offers it.
  `#improved_code_visible?` stays green through the shared count.
- The pitfalls rule, by table: gaps stored on the review, gaps stored in
  `graded_prose`, no gaps with `developing`, no gaps with `solid`, a Parsons
  `beginner`, a skipped section, and a `developing` review with an empty
  gap list.
- A convention spec: the predicate and the partial never name
  `ConceptMastery`.
- `spec/requests/dashboard_spec.rb` (submitted dashboard) and
  `spec/requests/history_spec.rb`: the block renders closed, with its
  summary text; nothing renders when the reference row is missing; a row
  without a guide falls back to `explanation` and `code_example`; pitfalls
  show only when the section has an essential gap; glossary terms are underlined once and
  markup is escaped.
- `spec/requests/section_rendering_characterization_spec.rb`: its
  submitted render gains the block where a fixture qualifies; re-record
  deliberately, reading the diff.
- `spec/views/disclosure_chevron_spec.rb` and
  `spec/views/page_stylesheets_spec.rb` if the block adds a class with its
  own rules.
- One system spec at phone width: the block is closed on load, opens on a
  tap, and a glossary term inside it opens its tooltip.
- No prompt snapshot changes: nothing here reaches a provider.
- The mailer spec stays unchanged, which pins that the email leaves it out.

## Docs and rules

- `.claude/rules/review.md`: one entry stating the predicate, the never-the-tier rule
  and the closed default.
- `.claude/rules/learn.md`: a line that the review reads
  `ConceptReference`'s guide fields, so a change to those fields checks the
  review too.
- `docs/decisions/first-exposure-teaching-in-the-review.md` for the full
  text, with the two decisions above. It replaces this spec as the
  reference, and `docs/decisions/stored-answer-keys.md` cites it there.
- `docs/code-notes/app/models/daily_response.md`: the `== 1` versus
  `.zero?` difference.

## Stop conditions

Stop and come back to you, without building further, if:

- the predicate needs anything beyond the exposure count and the section's
  own rating, which would put the mastery rule at risk
- most concepts have no guide yet. A count of `ConceptReference` rows with
  `#guide?`, by bucket, for the concepts the owner has seen, runs first. It
  is a read-only production query, run only with the owner's approval, and
  its output stays outside the repository; only the two counts go into the
  build PR. If fewer than about half those concepts have a guide, the short
  version is mostly the explanation fallback, which the section's disclosure
  already shows
- closed, the block takes more than one line on a 360-pixel-wide screen
- a glossary tooltip inside the open block can't be opened by tap on a phone
- the characterization re-record changes anything outside the review block
