# Implementation plan: the concept's short version in the review

This plan builds `docs/first-exposure-teaching-spec-2026-10-27.md`. It is one
PR from `main`, and it doesn't depend on the stored-answer-keys work. Work it
in the order below. Each step is a commit that passes its own specs, so the
branch stays green throughout.

**Settled in the spec:**
- pitfalls show only when the section has an essential gap
- both disclosures stay: the section's own reference and the review's short
  version
- the first qualifying section in `active_section_keys` order offers it
- closed by default; the review email leaves it out

**One departure from the spec, which the PR description must state.** The
spec puts the two new rules on `DailyResponse`. This plan puts them in a new
model, `ReviewShortVersion`, because:
- `app/models/daily_response.rb` is 321 lines, already over the 300-line
  guideline for `app/` files
- it already holds the 5 comments a file may have

The only change to `DailyResponse` is the exposure count it already
computes, made public so the new model can read it.

## Step 0. Before writing code

- Branch from `main`. If hmccutchen/code-gym-rails#592 (one reader for the
  grader's original `missed` and `essential_gaps`) has merged, use its reader
  in step 2. Otherwise read `graded_prose` the way `ReviewGrading` stores it.
- **The guide-coverage count**, the spec's first stop condition. It is a
  read-only production query, run only with the owner's approval, and its
  output stays outside the repository. Only the two counts go into the PR
  description. It runs in the web container (`railway ssh --service web --`):
  ```ruby
  bin/rails runner '
    ActiveRecord::Base.transaction do
      ActiveRecord::Base.connection.execute("SET TRANSACTION READ ONLY")
      user = User.find_by!(email: "OWNER_EMAIL")
      seen = user.daily_responses.where.not(submitted_at: nil).includes(:daily_exercise).flat_map do |r|
        r.concept_tags.filter_map { |s, c| [c, ConceptBucket.for(s, r.daily_exercise.language)] unless c.blank? || c == "other" }
      end.uniq
      guided = seen.count { |c, b| ConceptReference.find_by(concept: c, language: b)&.guide? }
      $stderr.puts "concepts seen: #{seen.size} · with a guide: #{guided}"
    end'
  ```
  **Stop and come back to the owner if fewer than about half have a guide.**
  In that case the short version would mostly repeat the section's own
  disclosure.

## Step 1. One exposure count, public on `DailyResponse`

A refactor with no change in behavior.
- `#improved_code_visible?` currently computes the bucket and the exposure
  count inline. Move that into a public
  `DailyResponse#concept_exposure_count(section)`, which returns nil for a
  blank or `"other"` tag.
- `#improved_code_visible?` then reads `concept_exposure_count(section) >= 2`.
- The comment that guards the key format moves with the lookup, so the file
  still holds 5 comments.

**Specs:**
- The existing `#improved_code_visible?` examples stay green.
- New examples for `#concept_exposure_count`: blank tag, `"other"`, first
  and second exposure, and a skipped section on a submitted day (it counts,
  per `ConceptExposureIndex`).

## Step 2. `ReviewShortVersion`, the two rules

**File:** `app/models/review_short_version.rb`. It is a decision object over
one response: `ReviewShortVersion.new(response)`. It isn't pure, since the
exposure count reads the user's `ConceptExposureIndex`, but it writes
nothing.

**`#offered?(section)`** is true when `qualifies?(section)`, and no earlier
key in `response.section_keys` with the same concept qualifies.

**`qualifies?(section)`** (private) is true when the concept is tagged, isn't
`"other"`, and either:
- `concept_exposure_count(section) == 1`, or
- `DailyResponse::AI_RATING_UNFAVORABLE.include?(response.ai_rating_for(section))`.

A `ConceptReference` row is not checked here. Sections that share a concept
share its row, so a missing row can't change which section offers it. The
partial renders nothing when the row is missing.

**`#essential_gap?(section)`** is true when the section has a rating
(`ai_rating_for`) and either:
- its rating is `beginner` or `developing`, or
- `RubricCheck` reads a non-empty gap list from the review as graded, with
  `graded_prose` merged over it.

This covers every case in the spec's table. A `developing` review with an
empty list counts, and so does a gap list with no readable rating. A skipped
section never counts.

**What the class never names:** `ConceptMastery`, drills or reinforcement.

**Specs** (`spec/models/review_short_version_spec.rb`, with unsaved records
where possible):
- **`#offered?`:**
  - first exposure
  - second exposure with `solid`
  - second exposure with `developing`
  - a skipped section on first and on later exposure
  - a blank tag and `"other"`
  - two sections sharing a concept on a first exposure, where only the first
    offers it
  - a later exposure with a `solid` section ahead of a `developing` one,
    where only the `developing` one offers it
- **`#essential_gap?`, as a table:**
  - gaps on the review
  - gaps only in `graded_prose`
  - no gaps with `developing`
  - no gaps with `solid`
  - a Parsons `beginner` with no gaps stored
  - a skipped section
  - `developing` with an empty list

## Step 3. The partial and where it renders

**Glossary helper:** `glossary_wrap_prose(text, seen: Set.new)` gains the
optional `seen:` keyword. `learn/_worked_example` passes it through as an
optional local. That way a term is underlined once across the whole short
version. Existing callers are unchanged, and a helper spec pins the shared
set.

**New partial:** `app/views/shared/_review_short_version.html.erb`. Its first
line is the required-locals comment: reference, bucket, show_pitfalls.

```erb
<details class="ref review-short-version">
  <summary><%= t("review.short_version.summary") %></summary>
  <div class="ref-body">
    tagline (strong) · guide_plain_language or explanation · worked example or
    code_example · pitfalls when show_pitfalls · "More on this concept" link
  </div>
</details>
```

- **Prose:** text goes through `glossary_wrap` with one `seen` set.
- **Worked example:** goes through `learn/_worked_example`, with that set.
- **Code example:** a row without a guide shows `code_example` through
  `highlighted_code(..., bucket)`.
- **Link:** `learn_concept_path(bucket, concept)`.
- **No terms in the summary,** never `role="button"`, and no inline `style=`.

**Placement:** `shared/_ai_review` renders the partial inside each
`review-block`, after the review fields and before `improved_code`. It
renders only when `ReviewShortVersion#offered?` and
`concept_reference_for(concept, bucket)` returns a row.

**Locale keys:** `review.short_version.summary` ("Show the short version")
and `review.short_version.more` ("More on this concept").

**Styles:** none new. `details.ref`, its chevron and `.ref-body` are already
in the layout, which both Today and History load. If spacing needs a rule,
it goes in the layout beside `details.ref`, never in a page sheet, since two
pages render it.

## Step 4. Request, characterization and system specs

**`spec/requests/dashboard_spec.rb` (the submitted dashboard) and
`spec/requests/history_spec.rb`:**
- the block renders closed, with its summary
- nothing renders when the reference row is missing
- a row with no guide falls back to `explanation` and `code_example`
- pitfalls show only with an essential gap
- glossary terms are underlined once across the block, and markup in a
  reference field renders escaped

**`spec/requests/section_rendering_characterization_spec.rb`:** re-record
its submitted render. Read the diff: it must change nothing outside the
review block. A change elsewhere is a stop condition.

**One system spec at phone width:** the block is closed on load, opens on a
tap, and a glossary term inside it opens its tooltip.

**Mailer spec:** stays untouched, which pins that the email leaves the block
out.

## Step 5. The never-the-tier convention spec

Add an example to `spec/conventions/app_source_spec.rb`, or a new
convention spec beside it. It reads `app/models/review_short_version.rb` and
`app/views/shared/_review_short_version.html.erb`, and fails if either names
`ConceptMastery`.

## Step 6. Docs, checks and the PR

**Docs:**
- `.claude/rules/review.md`: one entry covering the predicate, the
  never-the-tier rule and the closed default. Add
  `app/models/review_short_version.rb` and the partial to the rule's
  `paths:`.
- `.claude/rules/learn.md`: one line saying the review reads
  `ConceptReference`'s guide fields.
- `docs/decisions/first-exposure-teaching-in-the-review.md`: the full text,
  with both decisions, written from the spec. Once it exists, it replaces the
  spec as the thing to cite.
- `docs/code-notes/app/models/review_short_version.md`: the `== 1` against
  `.zero?` difference, and why the reference row isn't checked in the model.
- `docs/code-notes/app/models/daily_response.md`: `#concept_exposure_count`.
- `docs/file-map.md`: the new model and partial.

**Checks:**
- `bin/rubocop` and `bin/comment-check`.
- The full unit suite once, since `DailyResponse` and the review partial
  are shared.
- `spec/system` once.
- Grep for dead locals; `Lint/UselessAssignment` is off.

**Reviews:**
- The critical review and the layered review, each by its own agent.
- A third agent checks their findings against the code before anything
  changes.
- A PR comment lists what was fixed, what was rejected and why, and any
  issues opened.

**PR description:**
- what was built
- the departure from the spec, with its reason
- the two guide-coverage counts

**Intent log:** add the entry on the branch, then run `compose.rb` and
`check.rb`.

## Stop conditions

These come from the spec. Stop and come back to the owner, without building
further, if:
- fewer than about half the concepts the owner has seen have a guide
  (step 0)
- either rule needs anything beyond the exposure count and the section's
  own rating and review
- closed, the block takes more than one line on a 360-pixel-wide screen
- a glossary tooltip inside the open block can't be opened by tap on a phone
- the characterization re-record changes anything outside the review block
