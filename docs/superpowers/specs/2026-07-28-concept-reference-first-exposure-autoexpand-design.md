# Auto-expand ConceptReference on a concept's first-ever exposure

## Problem

`ConceptReference` renders as a collapsed `<details>` dropdown uniformly,
regardless of whether this is a user's first or fifth time encountering that
concept. This mirrors the app's deliberate "struggle first" philosophy
(`teaching_note` is locked until an attempt, `improved_code` is gated until a
concept's second exposure) — but that philosophy only makes sense when the
user has some foothold to reason from. On a concept's genuine first
appearance, there's nothing yet to retrieve or reason toward — it's not
productive difficulty, it's just missing information.

This was confirmed against a real incident: a user missed a collapsed
reference entirely on first encountering "closures in loops," precisely
because they didn't yet know there was something worth clicking.

## Decision

Stay collapsed by default in every case **except** a concept's literal first
exposure. Every other exposure (2nd+) stays exactly as it is today: collapsed,
available, not forced.

Scope: this applies only to the **live answering view** — the render path
where a section is unsubmitted and the user is actively working through it
(`dashboard/_exercise.html.erb`'s three inline sections, and
`_architecture_section.html.erb` when `submitted: false`). The read-only
render of a submitted day (`_answered_sections.html.erb`, and
`_architecture_section.html.erb` when `submitted: true`) — used by history and
the dashboard's post-submit state — is unchanged and always renders collapsed.
This matches the incident (the miss happened while answering) and keeps the
blast radius minimal.

No migration. This is a purely read-time display decision reusing the
existing per-user, per-concept exposure count (`User#concept_exposure_count`)
already built for gating `improved_code`. No changes to `teaching_note`
gating, `improved_code` gating logic, concept tagging, or
`ConceptReference`'s generation/storage mechanism.

## Design

### `ConceptReferencesHelper#first_exposure?`

New helper method, alongside the existing `concept_reference_for`:

```ruby
def first_exposure?(concept, bucket, date)
  return false if concept.blank? || concept == "other"
  current_user.concept_exposure_count(concept, bucket, on_or_before: date).zero?
end
```

Mirrors the blank/`"other"` guard in `DailyResponse#improved_code_visible?`
for consistency, even though those concepts never resolve to a cached
`ConceptReference` anyway. `on_or_before: date` is safe to use as "today" in
the unsubmitted path because `User#concept_exposure_index` only counts
**submitted** responses — today's in-progress answers can never inflate their
own first-exposure check.

### `shared/_concept_reference` partial

Add one optional local, `open` (default `false`):

```erb
<% open = local_assigns.fetch(:open, false) %>
<details class="ref"<%= " open".html_safe if open %>>
  ...
</details>
```

### Call sites

`dashboard/_exercise.html.erb` (three inline sections — code_review, pattern,
challenge; bucket is `exercise.language`, date is `exercise.date`):

```erb
<%= render "shared/concept_reference", reference: ref,
      open: first_exposure?(cr["concept"], exercise.language, exercise.date) %>
```

`_architecture_section.html.erb` (shared between submitted/unsubmitted;
bucket is the existing `"architecture"` constant, date is `response.date`):

```erb
<%= render "shared/concept_reference", reference: ref,
      open: !submitted && first_exposure?(arch["concept"], "architecture", response.date) %>
```

`_answered_sections.html.erb` — no changes. Its three `concept_reference_for`
calls keep rendering without an `open:` local, so the partial's default
(`false`) applies — collapsed, as today.

## Testing

- Helper spec for `first_exposure?`: blank concept → false; `"other"` → false;
  exposure count 0 → true; count ≥ 1 → false.
- View/request spec on the dashboard's unsubmitted state: a concept with no
  prior submitted exposure renders `<details ... open>`; a concept already
  exposed renders collapsed (no `open` attribute).
- Regression check: history and the post-submit read-only dashboard state
  still always render collapsed, regardless of exposure count.

## Out of scope

- Any change to `teaching_note` or `improved_code` gating.
- Any change to concept tagging or `ConceptReference` generation/storage.
- Auto-expand behavior on the read-only (submitted) render paths.
