# Restart Today's Set, and Account/Settings Page Polish

**Date:** 2026-08-06
**Status:** Approved

## Problem

The glossary search's "Clear" button surfaced a gap: there's no way for a
user to abandon their in-progress or already-submitted answers for today and
try the same problem set again from scratch. The only reset-adjacent action
today is "Generate new set" (`daily_exercises#regenerate`), which replaces
the problems themselves and is capped at once/day — it doesn't help someone
who just wants a clean slate on the *same* problems.

Separately, the account (`/account`) and settings (`/setup`) pages are
functional but under-designed: two near-duplicate ad hoc `<style>` blocks
with inconsistent spacing, no visual grouping of related fields, and a
misleading "Save key →" button that actually saves the key, language, *and*
implicitly sits above the separately-autosaving timezone field.

## Part 1: Restart today's set

### Route and controller

New member route, alongside the existing `review`/`email_review`/etc.
actions on `resources :responses`:

```ruby
resources :responses, only: [ :create ] do
  member do
    delete :start_over
    post :review
    post :email_review
    patch :self_explanation
    post :explain_differently
    post :follow_ups
  end
end
```

`ResponsesController#start_over` — added to the existing `set_response`
`before_action` list (`current_user.daily_responses.find(params[:id])`
already enforces ownership; a wrong ID 404s before this ever runs):

```ruby
# DELETE /responses/:id/start_over — abandon today's saved answers so the same
# problem set can be re-attempted from a blank state. Destroys the row
# outright (answers, ratings, feedback_text, ai_review, everything) rather
# than clearing fields in place — #create's find_or_initialize_by already
# handles a missing row cleanly, so the next autosave just creates a fresh
# one with no special-casing needed anywhere else.
def start_over
  return redirect_to root_path, alert: "This set has already been reviewed — nothing to start over." if @response.reviewed?
  return redirect_to root_path, alert: "You can only start over on today's set." unless @response.date == Date.current
  if @response.reviewing_since.present? && @response.reviewing_since > REVIEW_CLAIM_STALE_AFTER.ago
    return redirect_to root_path, alert: "A review is being generated for this — try again in a moment."
  end

  @response.destroy
  redirect_to root_path, notice: "Today's answers have been cleared — start fresh whenever you're ready."
end
```

Server-side guards are required, not optional. `set_response` scopes to
`current_user` but not to a date, so without the `Date.current` check a
crafted request destroys any past unreviewed response — and reviews are
optional here, so those history rows are common. The `reviewed?` and
`reviewing_since` checks protect mastery state: once
`ConceptMastery.record_review!` has moved tier/streak for a concept, this
action cannot undo it. Because `#review`'s provider call has no timeout, it
can outlive `REVIEW_CLAIM_STALE_AFTER`; `#review` therefore takes a row lock
(`@response.lock!`) before writing, so a mid-flight destroy aborts the whole
review transaction instead of committing mastery writes against a row that
no longer exists.

With those guards in place this only ever touches **today's**
`DailyResponse`. Past days' history in `/history` is completely untouched —
this is not an account-wide wipe.

### Visibility rule

The button renders when `response.persisted? && !response.reviewed?` — not
the `has_progress` rule sketched below. A submitted set with no review is
exactly the case a user most wants to redo, and `has_progress` would also
have offered the button on rows the server now refuses.

### UI

`dashboard/_exercise.html.erb`'s existing `.regenerate-row` becomes a two-
sided flex row. `has_progress` stays where it is, scoped to the regenerate
button's confirm copy; the start-over button uses the visibility rule above:

```erb
<% submitted = response.persisted? && response.submitted? %>

<div class="regenerate-row">
  <div>
    <% if exercise.regenerated_at.present? %>
      <p class="hint">You've already generated a new set today.</p>
    <% else %>
      <% confirm_msg = has_progress ?
           "This will replace today's problems and erase your answers so far. This can't be undone. Continue?" :
           "Generate a new set for today?" %>
      <%= button_to "Generate new set", regenerate_path, method: :post,
            class: "btn btn-ghost btn-sm",
            form: { data: { loading_form: true, loading_label: "Generating…",
                            confirm_message: confirm_msg } } %>
    <% end %>
  </div>

  <% if response.persisted? && !response.reviewed? %>
    <%= button_to "Start over", start_over_response_path(response), method: :delete,
          class: "btn btn-ghost btn-sm",
          form: { data: { loading_form: true, loading_label: "Starting over…",
                          confirm_message: "This will clear today's answers, ratings, and feedback " \
                                            "so you can start fresh. This can't be undone. Continue?" } } %>
  <% end %>
</div>
```

`.regenerate-row` gets `display:flex; justify-content:space-between;
align-items:center; flex-wrap:wrap; gap:.75rem;` added to its existing CSS
rule so the two buttons sit opposite each other, wrapping on narrow screens
rather than overlapping.

Reuses the layout's existing `data-loading-form` script verbatim (native
`confirm()` + in-flight spinner + bfcache-restore reset) — no new JS.

Renders identically in both the submitted and unsubmitted dashboard states,
since `.regenerate-row` already sits above both branches in the template.
After starting over, the visibility rule naturally evaluates false on the next
render (no persisted response, no answers), so the button disappears until
the user types again — no extra state to track.

### Non-goals

- No account-wide "clear all history" action — out of scope, per the
  clarified request. `/history` and all past `DailyResponse` rows are
  untouched by this feature.
- No confirmation-by-typing (unlike account deletion) — a native `confirm()`
  dialog is enough for a same-day, same-problems reset; the account page's
  danger zone remains the only place with something truly irreversible
  across days.

## Part 2: Settings button rename

`app/views/api_keys/edit.html.erb`: `"Save key →"` → `"Save preferences →"`.
Text-only change — the button already submits the key and language fields
together (`ApiKeysController#update` handles both, falling back to
`language_only_update` when the key field is blank), so "preferences" is
accurate regardless of which fields the user actually changed.

## Part 3: Visual polish for `/account` and `/setup`

Visual only — same fields, same grouping, same controllers/routes. No
content or structural changes.

### Shared conventions (applied independently to each page's own `<style>`
block, matching this app's existing per-page-style-block convention — no new
shared stylesheet)

- **One spacing rhythm.** Both pages currently mix 3rem/2rem/1rem margins ad
  hoc. Standardize: 2rem between major sections, 1rem within a section,
  matching the dashboard's `.section` rhythm.
- **Eyebrow section labels.** Small uppercase muted labels above each
  logical group, reusing the visual weight of the dashboard's
  `.section-label` (not literally shared CSS — each page keeps its own
  style block, but the same look: `font-size:.75rem; letter-spacing:.05em;
  text-transform:uppercase; color:var(--muted);`).
  - `/account`: "Account", "Generation", "Danger Zone"
  - `/setup`: "API Key", "Time Zone"
- **Card grouping.** Each labeled section wraps in a light card —
  `background:var(--surface); border:1px solid var(--border);
  border-radius:8px; padding:1.25rem;` — the same tokens already used for
  `.form-field input` and code snippets elsewhere, not a new palette.
- **Danger zone.** Keeps the card treatment above, but with a
  `border-color` tinted toward `var(--red)` instead of the current plain
  top rule, so it reads as a self-contained zone rather than a trailing
  section that happens to have a red heading.

### `/account` specifics

- "Settings →" upgrades from a bare `link_to` to a `btn btn-ghost`-styled
  link, matching "Log out" beside it in the actions row — same visual
  weight, not a stray text link next to two real buttons.
- Identity block (email + provider/language line), generation toggle, and
  danger zone each become their own card per the shared conventions above.

### `/setup` specifics

- API key field + language dropdown (inside the existing `form_with`) get
  wrapped in one "API Key" card.
- The time zone `select_tag`, which today lives outside the `form_with`
  block with different markup from the other two fields, gets the same
  `.form-field` visual treatment (label + select styled identically) inside
  its own "Time Zone" card — it stays functionally separate (still its own
  fetch-on-change autosave to `/profile`), only the visual treatment is
  unified.

## Testing

- `spec/requests/responses_spec.rb` (or wherever `ResponsesController`
  request specs live): `DELETE /responses/:id/start_over` destroys the response,
  redirects to root with the expected notice, and 404s for another user's
  response id.
- `spec/system/` coverage for the start-over button's visibility rule
  is optional/nice-to-have — the button's presence is
  already implied by existing dashboard system specs' fixtures; a dedicated
  assertion can be added if the implementer judges it worth the browser-spec
  cost, but request-spec coverage of the controller action is the required
  minimum.
- No new specs needed for the button rename or the visual polish (no
  behavior change) — existing request/system specs that assert on page text
  should still pass since neither page's controller behavior changes; grep
  for any spec asserting the literal string "Save key" and update it to
  "Save preferences".
