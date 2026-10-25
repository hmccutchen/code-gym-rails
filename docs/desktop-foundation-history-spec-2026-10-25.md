# Spec: Desktop foundation + History

This file is here for review and is removed from the branch before the PR
merges.

Checked against origin/main `38d3384`, which includes Settings on phone cards
(#512) and the Exercise mix controls (#545). The History view
(`app/views/history/index.html.erb`) and its 600px rule are the same as before
either. #512 added `overflow-wrap: anywhere` on `.review-block`, `.question`
and `.section-scenario` in the layout. #545 added the range slider and the
disabled switch row to `phone_cards.css`, and `FetchStubHelper` and
`ComputedColorHelper` to `spec/support/system_test_helper.rb`.

## Goal

Two things in one PR:

1. **The foundation every later desktop PR builds on:** a 900px-only
   stylesheet, a per-page wide container, a page wrapper for card pages that
   take the full container width, and shared layout spec helpers.
2. **History on it:** phone cards in place of the 600px bleed, and a desktop
   layout with a left rail.

Out of scope: every other page's layout, the month list, the nav, and
anything in `app/javascript`.

## Decisions this PR applies

- Desktop starts at 900px. Content is at most 1040px wide, centered, with the
  page gutters outside it. Only pages that ask for it get the wide
  container; `.container` itself doesn't change.
- From 600 to 899px, History takes the full container width.
- Every target is at least 44px tall at every width, desktop included.
- The rail holds the title, "N submitted sessions" and "Page X of Y". It has
  no month list.

## 1. `app/assets/stylesheets/desktop.css`

A new stylesheet, linked in the layout right after `phone_cards`:

```erb
<%= stylesheet_link_tag "phone_cards" %>
<%= stylesheet_link_tag "desktop" %>
```

### The 900px-only guarantee

Every rule in the file sits inside one `@media (min-width: 900px)` block.
Nothing sits outside it: no custom properties, no `@font-face`, no second
media query. This is how "the phone layout is unchanged by the desktop
rules" holds by construction, and two specs pin it (section 7, specs 1 and
8).

The link tag carries no `media` attribute. The file's own `@media` is the one
guard, because `ViewStyles` can check it. A spec can't check a `media`
attribute on the link.

Each rule is scoped to a page class (`.history-page`, and later
`.progress-page` and so on) or to the wide container. That's the same rule
`.claude/rules/pages.md` already sets for `phone_cards.css`.

The file holds at most 5 comments (`bin/comment-check`). Its reasoning goes in
`docs/code-notes/app/assets/stylesheets/desktop.md`.

### What this PR puts in it

```css
@media (min-width: 900px) {
  .container.container-wide { max-width: calc(1040px + var(--container-pad-left) + var(--container-pad-right)); }

  .history-page { display: grid; grid-template-columns: 240px minmax(0, 1fr); gap: 24px; align-items: start; }
  .history-rail { position: sticky; top: 24px; }
  .history-rail-page { display: block; }
  .history-page .history-entry { padding: 20px; }
  .history-page details.review { max-width: 65ch; }
}
```

- **Wide container.** The layout sets `box-sizing: border-box` on everything,
  so `max-width` includes `.container`'s padding. Building it from
  `--container-pad-*` puts the content box at exactly 1040px at any safe-area
  inset, and restates no gutter value (`container_gutter_spec` style). Below
  1040px of content, the gutters are the existing `max(1.5rem, inset)`
  (`max(2rem, inset)` at 1024px and up).
- **`minmax(0, 1fr)` and not `1fr`.** A grid track defaults to its content's
  minimum width. A long path or a wide code block would otherwise widen the
  column and scroll the page sideways.
- **The rail is sticky without a minimum-height guard.** It holds three short
  lines, about 200px at the largest text, which is under the shortest window
  in scope (430px, iPhone Pro Max in landscape).
- **65ch on the review.** Only the review disclosure is held to a reading
  width. Answers and code keep the full entry width.
- **20px card padding** at desktop, as on the boards. Phone keeps 16px.

## 2. The wide-container modifier

### Helper (`app/helpers/application_helper.rb`, next to `page_title`)

```ruby
def wide_page
  content_for(:container_width, "wide", flush: true)
end

def container_class
  content_for(:container_width) == "wide" ? "container container-wide" : "container"
end
```

`flush: true` means a view that calls `wide_page` twice still gets
`"wide"`, not `"widewide"`. Only one width exists, so there's no width
parameter (YAGNI). Progress, Learn, Today, Account and Settings call
`wide_page` in their own PRs.

### Layout

```erb
<div class="<%= container_class %>" data-pull-content>
```

Only the page container changes. `nav .inner` keeps `.container` and its own
1200px cap, so the nav row doesn't move. At 1920px the nav's content is
wider than the page's 1040px. That's accepted, since this PR leaves the nav
alone.

`container-wide` is a second class, never a replacement. The gutter
properties, the `.phone-page` margin formula, the pull-to-refresh hook and
`.section`'s `-1.5rem` bleed all still read `.container`.

## 3. `.card-page` in `phone_cards.css`

History needs the phone card gutter without Account and Settings' 480px cap,
so the gutter rule and the `[hidden]` rule are shared:

```css
.card-page { display: flex; flex-direction: column; gap: 16px; padding-bottom: 16px; }

@media (max-width: 599.98px) {
  .phone-page, .card-page {
    margin-left: calc(max(16px, env(safe-area-inset-left)) - var(--container-pad-left));
    margin-right: calc(max(16px, env(safe-area-inset-right)) - var(--container-pad-right));
  }
}

:is(.phone-page, .card-page) [hidden] { display: none; }
```

- `.phone-page` keeps its own flex rule and its `min-width: 600px` 480px cap.
  `.card-page` has no cap, so from 600px up it's the container's full width.
- The margin formula is written once, for both selectors.
  `container_gutter_spec` selects rules whose selectors include
  `.phone-page`, so its existing example still finds exactly one formula.
- The `[hidden]` comment stays, and the rule widens to the `:is` list. It's
  still one comment.

The entries **don't** take the `.card` class. `phone_cards.css` loads after
the layout, so `.card h2` (1rem, `.4rem` margin) has the same specificity as
`.section h2` and would win over it. That would shrink every nested section
title inside "Problems & answers". `.history-entry` gets the card's values
directly instead (section 4).

## 4. History markup and styles

### Markup (`app/views/history/index.html.erb`)

```erb
<% page_title t("history.index.title") %>
<% wide_page %>
<style>…</style>

<div class="card-page history-page">
  <div class="history-rail">
    <h1><%= t("history.index.title") %></h1>
    <p class="count"><%= t("history.index.count", count: @pagy.count) %></p>
    <% if @pagy.last > 1 %>
      <p class="history-rail-page"><%= t("history.index.page", page: @pagy.page, last: @pagy.last) %></p>
    <% end %>
  </div>

  <div class="history-entries">
    <%# empty state, the entries and the pagination nav, unchanged inside %>
  </div>
</div>
```

- `.page-header` becomes `.history-rail`. Dashboard and the admin pages keep
  their own `.page-header`.
- The rail is a `div`, not a `<header>` or an `<aside>`. It's the page's
  heading block, not a landmark.
- The rail's "Page X of Y" uses the existing `history.index.page` key, and
  shows only when the pager shows (`@pagy.last > 1`). Below 900px it's
  `display: none`, so a phone shows the page number once, in the pager. At
  desktop it shows in both the rail and the pager, which is the app's text
  and the boards' layout. No new locale keys.
- Inside `.history-entries`, nothing else changes: every entry keeps its
  `id="response-<id>"`, the `details.answers` and `details.review`
  disclosures, the newest review open on page 1, and Pagy's nav.

### Styles (History view `<style>`)

Remove:

- `.history-entry`'s `margin-inline: -1.5rem` bleed rule, inside
  `@media (max-width: 600px)`, and the comment above it ("Mirrors the
  layout's .section mobile rule; the values are coupled"), which goes false.
- `.history-entry`'s `margin-bottom: 1.5rem` and `box-shadow`. The flex gap
  does the spacing.
- `.page-header`'s margin, since `.card-page`'s gap replaces it.

Keep `.history-entry .section` (margin 0, radius and side borders, under
600px). The layout's 600px rule still bleeds every `.section` to the screen
edge until the Today phone PR replaces it, so nested sections inside a card
still need this override. Its comment changes to say why in one line, for
example: `/* The layout's 600px rule bleeds .section to the edge; inside an entry it stays inset. */`

Change or add:

| Selector | Declarations | Why |
|---|---|---|
| `.history-entry` | `padding: 16px; border-radius: var(--radius); background: var(--surface); border: 1px solid var(--border);` | the card's measurements, without the `.card` class |
| `.history-entries` | `display: flex; flex-direction: column; gap: 16px; min-width: 0;` | 16px between entries |
| `.history-rail h1` | `font-size: 1.5rem;` | the old `.page-header h1` |
| `.history-rail .count`, `.history-rail-page` | `color: var(--muted); font-size: .9rem;` | the old `.count` |
| `.history-rail-page` | `display: none;` | desktop shows it (section 1) |
| `details.answers summary`, `details.review summary` | `display: flex; align-items: center; min-height: 48px; padding-block: 0;` | 48px disclosures |
| `.pagination` | add `flex-wrap: wrap;` | fits 320px at the largest text |
| `.pagination a` | `display: inline-flex; align-items: center; min-height: 44px; padding: 0 1rem; border-radius: 999px;` | 44px pager buttons |

The empty state keeps its inline style, which now sits on the card
background. The chevron's `::before` rule in the layout doesn't change.
`disclosure_chevron_spec` pins its selector list, and the summaries become
flex rows that still draw it. Check the chevron's vertical alignment by eye
in the browser pane, since `translateY(-25%)` was tuned for an inline
summary.

The view holds 4 comments today. After the change it holds 3: the
nested-section one (rewritten), "Same partial as the dashboard's…" and
"Raw output: Pagy…".

### What each width looks like

| Width | History |
|---|---|
| under 600px | Cards `max(16px, inset)` from each edge, 16px padding and gaps. The rail is the title and count above the cards. |
| 600–899px | One column at the container's full content width, inside the container's gutters |
| 900px and up | A 240px sticky rail, a 24px gap, then the entries. Content is `min(1040px, viewport − gutters)`, centered. |

Two landscape cases cross the line. An iPhone at 844×390 with 47px insets
gets the one-column layout inside 47px gutters. An iPhone Pro Max at 932×430
with 59px insets gets the desktop grid inside 59px gutters, with 814px of
content.

## 5. Snapshots: recorded against main first

Two commits, in this order:

1. **Record-only commit.** Add `progress` and `learn` examples to
   `spec/requests/existing_account_pages_spec.rb` and record
   `spec/fixtures/page_snapshots/progress.html` and `learn.html` against
   unchanged app code. Nothing under `app/` changes in this commit, so the
   new fixtures are main's real output.
   - The Progress example needs a reviewed day, so at least one group shows
     standings, and a bucket with more than one group, so the bucket `h2`
     path renders.
   - The Learn example needs the featured concept, one concept with a
     reference and one without (so the prepare box shows), one drill (the
     drills box), and one recognition guide.
   - Both run under the spec's existing `travel_to(Time.utc(2026, 9, 29, 15))`,
     so the featured week is fixed.
2. **The change, then re-record all eight** with `UPDATE_PAGE_SNAPSHOTS=1`.
   The expected diff, which the PR description should state:
   - **All eight** gain one line, the `desktop` stylesheet `<link>`.
   - **`history.html`** also gains the `container container-wide` class, the
     `card-page history-page` wrapper, the `history-rail` block (no page line,
     since the fixture has one page), the `history-entries` wrapper, and its
     `<style>` changes.
   - **The other seven:** no other change. The container class stays
     `container` on all of them.

A reviewer can then read the second commit's fixture diff as the full
rendered effect of the PR.

## 6. Shared spec helpers: `spec/support/layout_helpers.rb`

A module included for `type: :system`. It moves out the helpers that
`small_screen_layout_spec.rb` and `phone_cards_spec.rb` each define:

```ruby
module LayoutHelpers
  LARGEST_TEXT = { "text_size" => "140", "line_spacing" => "loose", "font" => "atkinson" }.freeze
  LAYOUT_WIDTHS = [ 320, 390, 768, 899, 900, 1280, 1920 ].freeze

  def resize(width, height: 844) ...
  def page_width ...                     # document.documentElement.scrollWidth
  def sideways_overflow ...              # scrollWidth - clientWidth, 0 when nothing scrolls
  def set_safe_area(left: 0, right: 0, top: 0, bottom: 0) ...
  def apply_text_spacing ...             # the WCAG 1.4.12 override, moved as is
  def open_every_disclosure ...
  def rect(selector) ...                 # one element's bounding rect as a hash
  def rects(selector) ...                # every match's
end
```

- **`LARGEST` becomes `LayoutHelpers::LARGEST_TEXT`.** Today `LARGEST` is
  assigned inside the `RSpec.describe` block, which makes it a top-level
  constant. A constant in an included module isn't visible from a
  `describe` body's `[ … ].each` loop, which runs at class level. So the
  eight uses in `small_screen_layout_spec.rb` are rewritten with the
  qualified name.
- **`sideways_overflow`** compares `scrollWidth` with `clientWidth`, not
  with the window width. A classic scrollbar takes width from the viewport,
  and the new desktop widths are where it would show up. `page_width` stays
  for the examples that already compare against the width.
- **`set_safe_area`** keeps Chrome's
  `Emulation.setSafeAreaInsetsOverride`, now with `top` and `bottom` and
  keyword defaults. Existing calls `set_safe_area(left:, right:)` keep
  working.
- **`design_comparison_spec.rb`** has its own one-argument `resize(width)`.
  It keeps its own method, which overrides the module's, and nothing about
  it changes in this PR.

## 7. Specs for this PR

### View and helper specs (no browser)

1. **`spec/views/desktop_stylesheet_spec.rb`** (new)
   - every rule from `ViewStyles.stylesheet_rules("desktop.css")` has `media`
     equal to `["@media (min-width: 900px)"]`;
   - the file has at least one rule (so an empty file can't pass);
   - the layout source links `desktop` after `phone_cards`.
2. **`spec/views/container_gutter_spec.rb`** (extended): the
   `.container.container-wide` rule's `max-width` is
   `calc(1040px + var(--container-pad-left) + var(--container-pad-right))`.
   The two existing examples pass unchanged.
3. **`spec/helpers/application_helper_spec.rb`** (new file):
   - `container_class` is `"container"` by default;
   - after `wide_page` it's `"container container-wide"`;
   - calling `wide_page` twice still gives that.

### Request specs

4. **`spec/requests/history_spec.rb`**
   - Replace the "mobile gutter" example (`:574-585`). Its new assertions:
     - the body has no `margin-inline: -1.5rem` rule for `.history-entry`;
     - the `.history-entry .section` override is still there.
   - Add the rail examples:
     - the `h1` and the count are inside `.history-rail`;
     - with two pages, "Page 1 of 2" appears in both `.history-rail-page`
       and `nav.pagination` (the existing `pagination_nav` checks pass
       unchanged);
     - with one page, there's no `.history-rail-page`;
     - every entry, the empty state and the nav are inside
       `.history-entries`;
     - the container `div` has `container container-wide`.
5. **Wide on History only.** One example that visits root, learn, progress,
   setup and account, and finds the container's class is exactly `container`
   on each. When a later PR widens a page, it edits this list, so a page
   can't widen by accident.
6. **`spec/requests/existing_account_pages_spec.rb`**: the two new examples
   (section 5), and all eight snapshots re-recorded.

### System specs: `spec/system/history_layout_spec.rb` (new)

Setup reuses the long-path reviewed day from the existing History example in
`small_screen_layout_spec.rb:155-178`, with enough days for two pages, so
the rail line and the pager both render.

7. **No sideways scroll.** At each of `LAYOUT_WIDTHS`, at the default text
   and at `LARGEST_TEXT`, and at 320px also with `apply_text_spacing`:
   `sideways_overflow` is 0, before and after `open_every_disclosure`. The
   same loop runs once over root at 1280 and 1920 at the default text, to
   show a page without the modifier is unaffected.
8. **The phone layout is unchanged by `desktop.css`.**
   - At 390 and 899, record the rects of `.history-rail`, each
     `.history-entry`, and `nav.pagination`.
   - Set `document.querySelector('link[href*="desktop"]').sheet.disabled = true`
     and record them again. They're equal.
   - At 900, the same two recordings differ. This proves the file switches
     on exactly at the breakpoint.
9. **Phone geometry at 390, and at 320 with `LARGEST_TEXT`:**
   - each `.history-entry` is 16px from both edges, with 16px padding,
     `border-radius` 14px, and 16px between entries;
   - `details.answers > summary` and `details.review > summary` are at least
     48px tall;
   - `.pagination a` is at least 44px tall;
   - `.history-rail-page` is not displayed.
10. **Safe area on phone:**
    - 390px with 44px insets: entry edges at 44px;
    - 390px with a 20px left inset: edges at 20 and 16;
    - 844×390 with 47px insets: entries span the container's content box, at
      47px from each edge;
    - in each case, no sideways overflow.
11. **600–899:** at 768, each entry's left edge equals the container's left
    padding (24px) and its width equals the content box. The rail sits
    above the entries, not beside them.
12. **Desktop grid:**
    - at 900: `.history-rail` is 240px wide, the entries start 24px after
      it, and the content box is 900 − 48 wide;
    - at 1280 and 1920: the content box is 1040px wide with equal left and
      right margins;
    - `.history-rail-page` is displayed;
    - entry padding is 20px;
    - the open review's width is no more than 65ch, measured as
      `parseFloat(getComputedStyle(el).maxWidth)` against its rect.
13. **Sticky rail:**
    - at 1280×900, after scrolling 1000px, `.history-rail`'s top is within
      1px of 24;
    - at 932×430 with 59px insets: the desktop grid shows, the rail's left
      edge is 59px from the left, the entries' right edge is 59px from the
      right, and nothing overflows sideways.
14. **44px at desktop too:** at 1280, the same summary and pager height
    checks as spec 9.

### Existing specs that must pass unchanged

These cover pages and rules this PR touches indirectly, and none of their
assertions should need editing:

- `small_screen_layout_spec.rb`: only its helper definitions and the
  `LARGEST` references change. That includes the two History long-path
  examples and Account's "480px wide and centered in landscape" example,
  which runs at 844, still under 900.
- `phone_cards_spec.rb`, `display_preferences_spec.rb` (including its
  six-page no-sideways-scroll loop), `input_font_size_spec.rb` (the History
  review input), `live_regions_spec.rb`, `save_status_spec.rb`
  (`.history-pill`), `mobile_nav_menu_spec.rb`,
  `disclosure_chevron_spec.rb`, `reduced_motion_coverage_spec.rb` (no
  transition is added) and `palette_contrast_spec.rb` (no colour is added).

## 8. Docs in the same PR

- **New `docs/decisions/desktop-layout.md`:** the 900px breakpoint, the
  1040px column, the per-page modifier, the 600–899 rule per page, 44px at
  every width, and why there's no `(pointer: fine)` relaxation.
- **`.claude/rules/pages.md`:** a short entry naming that decision doc. It
  covers that `desktop.css` holds only 900px rules, scoped per page, and that
  `wide_page` is the one way to widen a page.
- **`docs/code-notes/app/assets/stylesheets/desktop.md`** (new): what each
  rule does, `minmax(0, 1fr)`, why the wide width is built from the gutter
  properties, and why the rail needs no height guard.
- **`docs/code-notes/app/assets/stylesheets/phone_cards.md`:** `.card-page`,
  and the shared margin and `[hidden]` rules.
- **`docs/code-notes/app/views/layouts/application.html.md`:**
  `container_class` and `wide_page`.
- **`docs/code-notes/app/views/history/index.html.md`** (new): the rail, the
  page line shown once on phone, why entries don't take `.card`, and why the
  nested-section override stays.
- **`docs/file-map.md`:** `desktop.css`, `layout_helpers.rb`, and the two new
  spec files.

## 9. Risks to check while building

- **320px at the largest text.** Today an entry spans the whole 320px with
  16px padding. Inset by 16px a side, it's 32px narrower, and a nested
  `.section` sits inside its 16px padding. The two existing long-path History
  examples are the check. If they fail, fix it in CSS (padding or wrapping)
  and don't weaken the assertion.
- **The chevron's alignment** in a flex summary (section 4).
- **The pager at 320px with the largest text.** `flex-wrap` keeps it on
  screen. Check that it wraps cleanly rather than squeezing the buttons
  below 44px.
- **The nav doesn't line up with the 1040px column at wide widths.** That's
  accepted (section 2).
