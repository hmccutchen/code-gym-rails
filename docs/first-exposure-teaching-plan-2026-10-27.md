# Implementation plan: the concept's short version in the review

This plan builds `docs/first-exposure-teaching-spec-2026-10-27.md`. It is one
PR from `main`, and it doesn't depend on the stored-answer-keys work. Work it
in the order below. Each step is a commit that brings its own specs, written
first, so the branch stays green throughout.

**Settled in the spec:**
- pitfalls show only when the section has an essential gap
- both disclosures stay: the section's own reference and the review's short
  version
- the first qualifying section in `active_section_keys` order offers it
- closed by default; the review email leaves it out
- the exposure count lives on `ConceptExposureIndex` (owner, after the plan
  review)
- one reader for the grader's original review comes first, closing #592
  (owner, after the plan review)

**Departures from the spec, which the PR description must list with their
reasons:**
- **A new model.** The spec puts the rules on `DailyResponse`. This plan
  puts them in `ReviewShortVersion`, because `app/models/daily_response.rb`
  is 321 lines, over the 300-line guideline for `app/` files, and already
  holds the 5 comments a file may have.
- **The reference row is checked in the partial, not the predicate.**
  Sections that share a concept share its row, so a missing row can't change
  which section offers it. The partial renders nothing when the row is
  missing.
- **Two locale keys,** `review.short_version.summary` and
  `review.short_version.more`, where the spec names one, since the block has
  a summary line and a link.

## Step 0. Before writing code

- Branch from `main`.
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

## Step 1. One reader for the review as graded (closes #592)

A refactor with no change in behavior.
- Add `ReviewProseVerdict.as_graded(review)` beside `ORIGINAL_KEY`. It
  returns the review with the grader's original fields (`graded_prose`)
  merged over the reworded ones, or nil when the review isn't a hash.
  `ReviewGrading#gaps_beside_their_prose` also moves `essential_gaps` under
  `graded_prose`, so the merge is the whole rule.
- Move the three hand-written readers onto it:
  - `app/services/response_review.rb` (`graded_missed`)
  - `script/model_comparison.rb` (the calibration rows)
  - `script/review_baseline_export.rb` (`stored_section`)

**Specs:** `review_prose_verdict_spec` for `.as_graded` with and without
`graded_prose`, and a non-hash. The three callers' existing specs stay green
unchanged.

## Step 2. One exposure count, on `ConceptExposureIndex`

A refactor with no change in behavior.
- Add `ConceptExposureIndex.key_for(section, concept, language)`, which
  returns `[concept, bucket]`, or nil for a blank or `"other"` tag. `.for`
  uses it while building the index.
- Add `#count_for(section, concept, language, on_or_before:)`, nil when
  `key_for` is nil, otherwise `#count` for that key.
- `DailyResponse#improved_code_visible?` calls `count_for`. A nil count keeps
  today's answer, true, and only a number is compared with `>= 2`. The "Must
  match ConceptExposureIndex's keys" comment goes, since nothing restates
  the keys any more.
- `ConceptReferencesHelper#first_exposure?` drops its own blank and
  `"other"` check where it can read `key_for`. It keeps `.zero?`, which is
  right before submit.

**Specs:**
- `concept_exposure_index_spec`: `key_for` and `count_for` for a blank tag,
  `"other"`, first and second exposure, and a skipped section on a submitted
  day (it counts).
- `daily_response_spec`: a new pinning example that `improved_code_visible?`
  stays true for a blank and an `"other"` tag. The existing examples stay
  green.

## Step 3. `ReviewShortVersion`, the two rules

**File:** `app/models/review_short_version.rb`. A decision object over one
response, `ReviewShortVersion.new(response, exposures:)`, where `exposures`
is a `ConceptExposureIndex`. It writes nothing and reads no database itself,
so its specs build an index from a hash of dates.

**`#offered?(section)`** is true when `qualifies?(section)`, and no earlier
key in `response.section_keys` with the same concept qualifies.

**`qualifies?(section)`** (private) is true when the section has a stored
review (`response.section_reviewed?(section)`; a skipped section's
walkthrough counts), and
`exposures.count_for(section, tag, language, on_or_before: response.date)`
is a number and either:
- it is `== 1`, or
- `response.ai_rating_unfavorable?(section)`.

**`#essential_gap?(section)`** is true when the section has a rating
(`ai_rating_for`) and either:
- `response.ai_rating_unfavorable?(section)`, or
- `RubricCheck` reads a non-empty gap list from
  `ReviewProseVerdict.as_graded(review)`.

That covers every case in the spec's table. A `developing` review with an
empty list counts, and so does a gap list with a `solid` rating. A skipped
section never counts. No rating list is written out here: both rules read
`ai_rating_unfavorable?`, the one place the unfavorable ratings are named.

**`RubricCheck`** gains a second reader. Its first line, "Log-only: nothing
rewrites a rating from this", stays true but no longer says the whole job,
so it becomes "Never rewrites a rating; its gap list also decides the short
version's pitfalls."

**What the class never names:** `ConceptMastery`, drills or reinforcement.

**Specs** (`spec/models/review_short_version_spec.rb`, unsaved records and a
hand-built index):
- **`#offered?`:**
  - first exposure
  - second exposure with `solid`
  - second exposure with `developing`
  - a skipped section on first and on later exposure
  - a partial review: an earlier section sharing the concept whose review
    failed doesn't qualify, so the later section offers it
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

## Step 4. The partial, where it renders, and its request specs

Write the request specs first, in this same commit.

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

**Placement:** `shared/_ai_review` builds one
`ReviewShortVersion.new(response, exposures: response.user.concept_exposures)`
above its section loop. `User#concept_exposures` is memoized, so /history
builds the index once per page. Inside each `review-block`, after the review
fields and before `improved_code`, it renders the partial only when
`#offered?` and `concept_reference_for(concept, bucket)` returns a row.

**Locale keys:** `review.short_version.summary` ("Show the short version")
and `review.short_version.more` ("More on this concept").

**Styles:** none new. `details.ref`, its chevron and `.ref-body` are already
in the layout, which both Today and History load. If spacing needs a rule,
it goes in the layout beside `details.ref`, never in a page sheet, since two
pages render it.

**Request specs,** in `spec/requests/dashboard_spec.rb` (the submitted
dashboard) and `spec/requests/history_spec.rb`:
- the block renders closed, with its summary
- nothing renders when the reference row is missing
- a row with no guide falls back to `explanation` and `code_example`
- pitfalls show only with an essential gap
- glossary terms are underlined once across the block, and markup in a
  reference field renders escaped

**`spec/requests/section_rendering_characterization_spec.rb`:** its
submitted fixture has no review and no tags, so the block never appears
there. Add a reviewed, tagged fixture (a first exposure with a low grade)
with a `ConceptReference` row. Assert the block appears, and that the page
outside the review block matches the same fixture rendered without it. Any
difference outside the block is a stop condition.

## Step 5. System spec

One system spec at phone width (360 pixels):
- the block is closed on load, and its closed `<summary>` is one line high
  (its height is at most one line-height), which measures the spec's
  360-pixel stop condition
- it opens on a tap
- a glossary term inside it opens its tooltip on a tap

**Mailer spec:** stays untouched, which pins that the email leaves the block
out.

## Step 6. The never-the-tier convention spec

Add an example to `spec/conventions/app_source_spec.rb`, or a new
convention spec beside it. It reads `app/models/review_short_version.rb` and
`app/views/shared/_review_short_version.html.erb`, and fails if either names
`ConceptMastery`, as the spec asks.

## Step 7. Docs, checks and the PR

**Docs:**
- `.claude/rules/review.md`:
  - one entry covering the predicate, the never-the-tier rule and the
    closed default
  - the grading-rubric entry adds that `RubricCheck`'s gap list also decides
    the pitfalls
  - add `app/models/review_short_version.rb` and the partial to the rule's
    `paths:`
- `.claude/rules/learn.md`: one line saying the review reads
  `ConceptReference`'s guide fields.
- `docs/decisions/first-exposure-teaching-in-the-review.md`: the full text,
  with all the decisions, written from the spec. Once it exists, it replaces
  the spec as the thing to cite.
- `docs/code-notes/app/models/review_short_version.md`: the `== 1` against
  `.zero?` difference, and why the reference row isn't checked in the model.
- `docs/code-notes/app/models/concept_exposure_index.md`: `key_for` and
  `count_for` as the one home of the key rule.
- `docs/code-notes/app/models/review_prose_verdict.md`: `.as_graded`.
- `docs/file-map.md`: the new model and partial.
- Close #592 from the PR description.

**Checks:**
- `bin/rubocop` and `bin/comment-check`.
- The full unit suite once, since `DailyResponse`, `ConceptExposureIndex`
  and the review partial are shared.
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
- the departures from the spec, with their reasons
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
  (step 5)
- a glossary tooltip inside the open block can't be opened by tap on a phone
- the characterization comparison shows a change outside the review block
  (step 4)
