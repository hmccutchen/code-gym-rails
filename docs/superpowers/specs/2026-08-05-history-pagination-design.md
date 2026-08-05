# History Pagination + Parsons Arrow Removal

Date: 2026-08-05

## Problem

`HistoryController#index` loads every submitted session a user has ever
recorded and renders all of them into one page. Each entry renders a full
problem set, the user's answers, and an AI review, so the page grows without
bound — one row per user per weekday. It is already the heaviest page in the
app and it only gets heavier.

Paginate it: 10 sessions per page, offset-based, using the `pagy` gem.

A second, unrelated-in-code but same-page change ships alongside it: the
Parsons Problem section's up/down arrow buttons are removed from the default
render, leaving drag-and-drop as the primary input.

## Part 1 — History pagination

### Gem and wiring

Add to the Gemfile:

```ruby
gem "pagy", "~> 43.6"
```

Pagy 43 is a full API rewrite. The `Pagy::Backend` / `Pagy::Frontend` /
`pagy_nav` / `pagy_url_for` API described by nearly all existing
documentation and blog posts is gone. The v43 API used here is
`include Pagy::Method`, `pagy(:offset, scope, limit:)`, and helper methods on
the returned pagy object (`@pagy.previous_tag`, `@pagy.next_tag`,
`@pagy.page_url`).

No `config/initializers/pagy.rb`. Pagy 43 requires no configuration, and
every option this app needs (`limit`, `raise_range_error`) is passed at the
single call site, which keeps the page size visible where it is used instead
of hidden in a global.

`include Pagy::Method` goes in `HistoryController`, not
`ApplicationController`. History is the only paginated page, and this avoids
editing shared, load-bearing infrastructure for a single-page feature.

### Query

Add a scope to `DailyResponse`:

```ruby
scope :submitted, -> { where.not(submitted_at: nil) }
```

`HistoryController#index` becomes:

```ruby
class HistoryController < ApplicationController
  include Pagy::Method

  rescue_from Pagy::RangeError, with: :redirect_to_last_page

  def index
    @pagy, @responses = pagy(
      :offset,
      current_user.daily_responses.submitted
                  .includes(:user, :daily_exercise, :review_follow_ups)
                  .order(date: :desc),
      limit: DailyResponse::HISTORY_PAGE_SIZE,
      raise_range_error: true
    )
  end

  private

  def redirect_to_last_page(error)
    redirect_to history_path(page: error.pagy.last)
  end
end
```

The existing `includes` is preserved, so the change introduces no N+1.

### Out-of-range pages

Pagy 43's default behavior for an out-of-range page is to silently serve an
empty page. On this page that would render the "No submitted sessions yet"
empty state to a user who has plenty of sessions — actively misleading.
`raise_range_error: true` plus the `rescue_from` above redirects to the last
real page instead.

`?page=abc`, `?page=0`, and negative values are already clamped to page 1
inside Pagy's `Request#resolve_page` (`[page.to_s.to_i, 1].max`), so they need
no handling here and raise nothing.

With zero submitted sessions, `last` is 1 and page 1 is in range, so the empty
state still renders normally.

### The post-review redirect

`ResponsesController#history_anchor` currently returns
`history_path(anchor: "response-#{@response.id}")`. Once History is paginated
that anchor silently does nothing whenever the target response is not on
page 1.

Add to `DailyResponse`:

```ruby
HISTORY_PAGE_SIZE = 10

def history_page
  newer = user.daily_responses.submitted.where("date > ?", date).count
  (newer / HISTORY_PAGE_SIZE) + 1
end
```

History is ordered `date: :desc`, so the count of strictly-newer submitted
sessions is the response's zero-based position in that ordering. The model
owns this because it is a fact about where a response sits in its own user's
history, and it is directly unit-testable there.

An unsubmitted response has no History entry to anchor to, so `history_page`'s
result is meaningless for one. This is not guarded: `history_anchor` is only
reached from the review path, which operates on submitted sessions.

`history_anchor` becomes:

```ruby
def history_anchor
  page = @response.history_page
  history_path(page: (page unless page == 1), anchor: "response-#{@response.id}")
end
```

Passing `nil` makes Rails omit the parameter, so page 1 keeps its existing
clean `/history#response-N` URL and existing expectations about that URL hold.

The `index_daily_responses_on_user_id_and_date` unique index already covers
both the ordered scan and the `date > ?` count. No migration is required.

### View

`app/views/history/index.html.erb`:

- The header count uses `@pagy.count`, the total across all pages. Using
  `@responses.size` would read "10 submitted sessions" forever once a user
  passes ten.
- The auto-open rule for the newest entry becomes `i.zero? && @pagy.page == 1`.
  The rule's intent is "open the newest entry"; without the page check, page 3
  would open its first entry too, which is not the newest anything. Pages 2 and
  beyond render fully collapsed.
- Navigation renders at the bottom, only when `@pagy.last > 1`:

```erb
<nav class="pagination" aria-label="History pages">
  <%== @pagy.previous_tag(text: "← Newer") %>
  <span>Page <%= @pagy.page %> of <%= @pagy.last %></span>
  <%== @pagy.next_tag(text: "Older →") %>
</nav>
```

`previous_tag` and `next_tag` render themselves as `aria-disabled` anchors at
the ends of the range, so no conditional is needed around them. They emit no
CSS classes and require neither Pagy's stylesheet nor any JavaScript, which
matters because this app's layout loads no Turbo or Stimulus.

The `<%==` raw output operator is required: Pagy returns a pre-escaped HTML
string without calling Rails' `html_safe`, so `<%=` would escape it and render
visible markup.

Styles for `.pagination` go in this page's own `<style>` block, not the
layout. The layout is reserved for styles shared across pages (as
`_answered_sections` requires); nothing outside History renders this nav.

### Tests

`spec/requests/history_spec.rb`:

- 11 submitted sessions render 10 entries on page 1 and the 11th on page 2.
- The header count reports 11 on both pages.
- No nav renders with fewer than 11 sessions.
- On page 1 the next link is enabled and the previous link is disabled; on the
  last page the reverse.
- An out-of-range page redirects to the last page.
- `?page=abc` renders page 1.
- Exactly one entry auto-opens on page 1 and none on page 2.

`spec/models/daily_response_spec.rb`:

- `history_page` returns 1 for the newest session and 2 for the 11th.
- It ignores drafts and other users' sessions.

`spec/requests/responses_spec.rb`:

- Reviewing a session that sits on page 2 redirects to
  `/history?page=2#response-N`.
- Reviewing a recent session redirects without a `page` parameter.

Two existing assertions were checked and remain green unchanged: the "exactly
one open `details.answers`" test uses two entries, and the script-dedup tests
use three to four — all on page 1.

## Part 2 — Parsons Problem arrow removal

### Current state

`_parsons_problem_section.html.erb` renders a `.parsons-controls` div with
up/down buttons inside every unsubmitted block. An inline classic script wires
them, and a module script layers SortableJS drag on top from a pinned CDN URL.
The current comments describe the arrows as the baseline and drag as the
enhancement: if the CDN is unreachable, the arrows are the only way to answer.

### Change

Remove `.parsons-controls` from the default server render. Drag becomes the
primary input; the arrows become a recovery path that appears only when drag is
unavailable.

The `.parsons-controls` CSS rule in the layout stays as-is, since the injected
buttons reuse it.

The inline classic script changes from wiring existing buttons to exposing a
builder on the list element:

```js
list.parsonsAddControls = () => { /* create both buttons per block, attach
                                    the same handlers, call syncHiddenField */ }
```

The move handlers and `syncHiddenField` are otherwise unchanged.

Controls are injected in two cases:

1. The module script's existing `catch` — the CDN errored or the module failed
   to load.
2. A 3000ms timeout, set in the classic script, that injects controls into any
   list still lacking `data-sortable-done`.

The timeout is not redundant. If the CDN request hangs rather than errors,
`await import` never rejects and `catch` never runs. Without the timeout, a
blocked or stalled network would leave the section permanently unanswerable —
which is precisely the failure the existing comments protect against. A short
delay before the arrows appear is correct behavior: during that window drag
does not work either.

The comments describing the arrows as "the baseline" become false and are
rewritten to describe drag as primary and arrows as recovery.

### Touch drag behavior

With arrows removed from the default view, drag is the sole input on phones,
including the installed PWA that motivated this change. SortableJS with the
current `{ animation: 150 }` options begins a drag on touchstart, which
competes with page scrolling.

Add `delay: 150, delayOnTouchOnly: true` so a touch drag requires a brief hold
and ordinary swipes continue to scroll the page. Mouse dragging is unaffected.

### Tests

- A request spec asserts the unsubmitted server-rendered markup no longer
  contains `parsons-controls`.
- A request spec asserts the emitted script contains the injection path.
- One `spec/system/` spec against the `FakeService` user (`provider: "fake"`)
  confirms no arrows are present when SortableJS loads successfully. The
  injection behavior itself is only meaningfully observable in a real browser.
  (Implementation note: the spec pre-seeds a `DailyExercise` whose third
  section is `parsons_problem` rather than letting the dashboard generate one.
  `FakeService` returns every section kind, but only one third renders and
  `ExerciseSection.thirds` precedence makes `architecture` win every time, so
  a generated fake-provider dashboard never shows a Parsons section.)

The existing `spec/requests/history_spec.rb:58` assertion that a submitted
Parsons render contains no `parsons-move-up` passes unchanged: the script block
is emitted only for unsubmitted sections, so that spec's page contains neither
the buttons nor the script text.

## Out of scope

- Keyset pagination. The user asked for offset, and the ordering column
  (`date`) is unique per user, but offset is simpler and the data volume is
  small.
- Pagination anywhere other than History.
- Numbered page links. Previous/next with "Page X of Y" matches this app's
  minimal, no-JS convention.
- Self-hosting SortableJS. Mermaid and highlight.js already load from the same
  CDN; changing that posture is a separate decision.
