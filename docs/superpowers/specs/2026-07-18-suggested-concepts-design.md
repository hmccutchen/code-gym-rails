# Suggested Concept Tracking & Admin Review — Design

## Problem

`AiService#normalize_concepts` currently maps any off-vocabulary concept a
provider returns to `"other"` and discards the original string. That's a
missed signal: if the same off-list concept keeps showing up, it's likely a
real gap in `RAILS_CONCEPTS`/`JS_CONCEPTS`, not model noise. This spec adds a
background trail that captures those suggestions and a small admin review
surface to act on them — without automatically or silently growing the
vocabulary, and without changing anything the user experiences in the
moment (off-vocabulary concepts still normalize to `"other"` for that
response).

## Scope

- New `SuggestedConcept` table + model that records/aggregates off-vocabulary
  concept suggestions from generation.
- A hook in `AiService#normalize_concepts` that records a suggestion whenever
  it maps a concept to `"other"`.
- A simple admin-only review page listing suggestions by frequency, with
  "promote" (bookkeeping only) and "dismiss" actions.
- Env-var-based admin gating (no new admin role/flag on `User`).

Out of scope (explicitly):
- Automatically or silently adding concepts to `RAILS_CONCEPTS`/`JS_CONCEPTS`.
  Those stay frozen Ruby constants; shipping a promoted concept into the live
  vocabulary remains a manual code PR (see Decision Points below).
- Fuzzy/similarity grouping of near-duplicate suggested names (v2 idea, not
  built here — see Decision Points).
- Anything about `ConceptReference` beyond the read-only interface this
  feature depends on (see Decision Points — that model is being built in a
  separate session).
- Changes to magic-link auth, Resend/SMTP, `/test_login`, teaching_note
  gating, the reading-tip button, timezone work, the language-preference
  spec, or the `ConceptReference` library spec itself.

## Data Model

New table `suggested_concepts` (**migration** — flagged explicitly, this is
the only schema change in this feature):

```ruby
create_table :suggested_concepts do |t|
  t.string   :language,        null: false   # "ruby_rails" | "javascript" — validated against AiService::LANGUAGE_CONFIG.keys
  t.string   :normalized_name, null: false   # dedup key: name.to_s.strip.downcase.squeeze(" ")
  t.string   :display_name,    null: false   # original casing/spacing as first seen; shown to admins; never overwritten on repeat sightings
  t.integer  :occurrences,     null: false, default: 1
  t.datetime :first_seen_at,   null: false
  t.datetime :last_seen_at,    null: false
  t.string   :status,          null: false, default: "pending"   # "pending" | "promoted" | "dismissed"
  t.datetime :reviewed_at
  t.bigint   :reviewed_by_id                  # nullable FK to users — set on promote/dismiss
  t.timestamps
end
add_index :suggested_concepts, [:language, :normalized_name], unique: true, name: "index_suggested_concepts_on_language_and_normalized_name"
add_index :suggested_concepts, :status
```

`SuggestedConcept` model:
- `belongs_to :reviewed_by, class_name: "User", optional: true`
- Validations: `language` inclusion in `AiService::LANGUAGE_CONFIG.keys`;
  presence of `normalized_name`/`display_name`; `status` inclusion in
  `%w[pending promoted dismissed]`.
- `SuggestedConcept.record!(language:, name:)` — the only write entry point
  used by generation:
  - Computes `normalized_name = name.to_s.strip.downcase.squeeze(" ")`.
  - No-ops (returns `nil`) if `normalized_name` is blank or equals `"other"`
    — a literal `"other"` from a provider isn't a real suggestion.
  - `find_or_initialize_by(language:, normalized_name:)`; on first save sets
    `display_name` to the original `name`, `occurrences: 1`,
    `first_seen_at`/`last_seen_at` to now. On a repeat, increments
    `occurrences` and bumps `last_seen_at`; `display_name` is **not**
    overwritten, so casing shown to admins stays stable across sightings.
  - Wrapped to tolerate a concurrent-insert race the same way
    `GenerateDailyExercisesJob` already handles `DailyExercise` uniqueness:
    rescue `ActiveRecord::RecordNotUnique`, re-fetch, and retry the
    increment once.

## Capture Hook

`AiService#normalize_concepts`'s signature is unchanged — it only needs
`language` and the raw provider-returned concept string, both already in
scope:

```ruby
def normalize_concepts(problem_set, language = "ruby_rails")
  concepts = config_for(language)[:concepts]

  problem_set.each_value do |section|
    next unless section.is_a?(Hash) && section.key?("concept")
    original = section["concept"]
    unless concepts.include?(original)
      section["concept"] = "other"
      record_suggested_concept(language, original)
    end
  end
  problem_set
end

def record_suggested_concept(language, name)
  SuggestedConcept.record!(language: language, name: name)
rescue => e
  Rails.logger.warn("SuggestedConcept recording failed: #{e.message}")
end
```

This keeps the recording path simple: **no `daily_exercise_id` or `user_id`
is stored per suggestion** in v1, per your call to track only count + first/
last seen, not per-occurrence context. No existing call site needs to
change — both direct calls to `normalize_concepts` in
`spec/services/ai_service_spec.rb` keep working unmodified.

Recording failures are swallowed and logged (`rescue => e;
Rails.logger.warn`), matching the existing `log_usage` convention in
`AiService` — a bug in this bookkeeping path must never break exercise
generation. This hook does not change generation's return value or timing;
`"other"` is still what's persisted to that response's `concept_tags`.

## Admin Gating

No admin role or flag exists anywhere in the app today (only the
env-var-gated `/test_login` bypass). This feature adds the same pattern:

```ruby
# config/initializers or a constant on the controller
ADMIN_EMAILS = ENV.fetch("ADMIN_EMAILS", "").split(",").map { |e| e.strip.downcase }
```

`Admin::BaseController < ApplicationController` (inherits the app's existing
session/`current_user` machinery — no separate auth stack) adds a
`before_action :require_admin!` that redirects to `root_path` with an alert
if `current_user.email` isn't in `ADMIN_EMAILS`. Because gating is
env-var-based rather than a persisted role, `current_user` in an admin
action is still an ordinary `User` row that happens to match the allowlist
— `reviewed_by: current_user` on promote/dismiss resolves exactly the same
way it would anywhere else in the app, no special-casing needed.

## Admin Review UI

New routes, namespaced under `/admin`:

```ruby
namespace :admin do
  resources :suggested_concepts, only: [:index] do
    member do
      patch :promote
      patch :dismiss
    end
  end
end
```

`Admin::SuggestedConceptsController < Admin::BaseController`:
- `#index` — lists `SuggestedConcept` rows, default-filtered to
  `status: "pending"`, ordered by `occurrences desc`. Each row shows
  language, `display_name`, `occurrences`, `first_seen_at`, `last_seen_at`,
  and whether `ConceptReference.exists?(language:, concept: normalized_name)`
  is already true (surfaced as a hint, not enforced here).
- `#promote` — **bookkeeping only.** Requires
  `ConceptReference.exists?(language: record.language, concept:
  record.normalized_name)`; if false, redirects back with an alert
  ("Add a ConceptReference for this concept first."). If true, updates
  `status: "promoted"`, `reviewed_at: Time.current`,
  `reviewed_by: current_user`. This action **never** touches
  `RAILS_CONCEPTS`/`JS_CONCEPTS` — actually shipping the concept into the
  live vocabulary is a separate, manual code change (see Decision Points).
- `#dismiss` — sets `status: "dismissed"`, `reviewed_at`, `reviewed_by`, with
  no `ConceptReference` requirement (for suggestions judged not worth
  pursuing).

View is a plain server-rendered table (reuses the app's existing inline
`<style>`-per-view convention seen in `dashboard/show.html.erb`) — no new
JS, no Turbo Streams needed for this internal tool.

## Decision Points (explicitly flagged)

1. **Frozen vocabulary constants vs. DB-backed vocabulary.** Recommendation:
   keep `RAILS_CONCEPTS`/`JS_CONCEPTS` as frozen Ruby array constants
   (option a). Promotion through this feature is bookkeeping only; actually
   adding a concept to the live vocabulary still requires a small code PR.
   This matches the existing architecture's intent (the vocabulary is
   deliberately fixed/curated) and keeps promotion rare and reviewed rather
   than a live toggle. Rejected alternative: move the vocabulary into the
   database (option b) — would let promotion skip a deploy, but there's no
   evidence promotion needs to be that frequent, and it would add write-time
   validation complexity (prompt-building code currently assumes a frozen,
   known-at-boot-time array) for no clear benefit right now.

2. **`ConceptReference` sequencing.** This feature's `#promote` guard clause
   depends on `ConceptReference.exists?(language:, concept:)` existing with
   that exact interface. That model does not exist in this codebase as of
   this spec (no matches in the codebase; the `add-references` branch has no
   commits yet) and is being built separately. Two sequencing options:
   - **(Recommended)** Implement this entire feature *after*
     `ConceptReference` lands, so the `#promote` guard is real from day one
     and its specs aren't stubbing a model that doesn't exist yet.
   - Implement everything except the `ConceptReference` existence check now
     (index, capture hook, dismiss action all work standalone), landing the
     one guard clause in `#promote` as a small follow-up once
     `ConceptReference` exists. Riskier only in that `#promote` would need a
     temporary no-guard behavior (or be entirely disabled) in between.

3. **Fuzzy/similarity grouping.** Out of scope for v1. Suggestions are
   deduped only by exact match after `strip.downcase.squeeze(" ")`
   normalization — e.g. `"N+1 Queries!!"` and `"n_plus_one_queries"` would
   count as two separate rows, not one. Flagged as a v2 idea (e.g. trigram
   similarity, or a manual admin "merge into" action) but not built now.

4. **Dismiss status.** Added beyond the original ask: a `dismissed` status
   (alongside `pending`/`promoted`) so admins have a way to mark clear noise
   as reviewed-and-rejected, keeping the pending queue meaningful over time.
   Flagging in case you'd rather leave this out and only ever grow the
   pending queue.

## Testing Plan

- **`SuggestedConcept` model spec:** `.record!` creates a new row on first
  sighting with `occurrences: 1` and the original casing in `display_name`;
  a second call with a differently-cased/whitespaced but
  normalized-equivalent name increments the existing row's `occurrences` and
  bumps `last_seen_at` without changing `display_name`; a literal `"other"`
  name is a no-op (no row created); validations reject an unrecognized
  `language` or `status`.
- **`AiService#normalize_concepts` spec:** an off-list concept both
  normalizes to `"other"` *and* triggers `SuggestedConcept.record!` with the
  original string; a concept already in the vocabulary triggers no
  recording; a recording failure (stubbed to raise) is swallowed and logged,
  and generation's return value is unaffected.
- **`Admin::SuggestedConceptsController` request specs:** a non-admin
  (`current_user.email` not in `ADMIN_EMAILS`) is redirected away from every
  action; an admin sees pending suggestions ordered by `occurrences desc`;
  `#promote` succeeds and sets `status`/`reviewed_at`/`reviewed_by` when a
  matching `ConceptReference` exists, and redirects with an alert (no state
  change) when it doesn't; `#dismiss` succeeds regardless of
  `ConceptReference`. (These specs necessarily depend on `ConceptReference`
  existing — see Decision Point 2 on sequencing.)
