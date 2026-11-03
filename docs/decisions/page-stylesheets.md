# Page stylesheets

Each page that has styles of its own keeps them in one file,
`app/assets/stylesheets/pages/<page>.css`: its phone rules first, then its
desktop rules in one `@media (min-width: 900px)` block at the end. History,
Progress and the Learn index moved first, then Account and Settings, whose
partials' `<style>` blocks joined their page's sheet in the order they
rendered, then Today, whose dashboard partials' `style` attributes, and the
submitted day's review heading's, became classes in its sheet. The response
partials Today shares with History lost theirs too, to a layout class or the
`hidden` attribute, since History never loads Today's sheet. Today has no
desktop rules yet, so its sheet has no 900px block.

## Why a sheet per page

A page's styles had spread across three places: the layout's `<style>`, which
every page downloads, the view's own `<style>`, rendered in the body, and
`desktop.css`, where a desktop rule needed a more specific selector than the
view's rule it replaced. One file per page puts a page's rules in one place,
loads them only on that page, and lets a desktop rule win its ties with the
page's phone rules by coming last in the same file.

## How a page links its sheet

A view calls `page_stylesheet "history"` beside `page_title` and `wide_page`.
The layout links `pages/<name>` right after `desktop` and before the display
sheets. After `desktop`, so the page's rules win ties with the shared sheets
as a view's `<style>` did. Before `display` and `display_light`, because those
are the user's display preferences and load last on purpose. Their overrides
of page rules (the light palette's field border and rung colours) already
outweigh them, so the order is a margin, not what makes them win. One sheet
per page: a second call replaces the first.

A component that several pages render keeps its styles in
`components/<name>.css`, and each of those pages calls
`component_stylesheet "<name>"` (#569). The layout links every component
sheet named once, in the order first named, right after `desktop` and ahead
of the page's own sheet, so the page's rules win their ties with a shared
component's. `ApplicationHelper#linked_stylesheets` gives that list. The
authenticator setup, sign-in-again and recovery codes pages were the first:
their shared `authenticators/_styles` partial became
`components/authenticator.css`. The admin judge solves and suggested
concepts pages link `components/table_scroll.css`, whose `.table-scroll` box
lets each table scroll sideways on a phone rather than widen the page
(#574). Each box is a focusable region named by its table's heading, since
the judge solves tables hold nothing else a keyboard could reach their
hidden columns through. It is a component sheet rather than a layout rule because only those
two pages use it, so the pages everyone else loads don't carry it.
`spec/views/page_stylesheets_spec.rb` holds `components/` to exactly the
names views pass to `component_stylesheet`.

## What stays shared

A rule stays in the layout, or in `phone_cards.css`, when more than one page
uses its class: the featured card (Today and Learn), `.history-pill` (History
and Today's submitted day), `.learn-intro` (Progress and Learn), the
disclosure chevron rule, and the Learn concept and lesson pages' rules, which
aren't part of the page layout work. A partial's styles go in the sheet of
the page it renders on, or, when it renders on several pages, in a small
shared sheet named for the component. `spec/conventions/app_views_spec.rb`
fails when a partial styled by a page sheet is rendered anywhere but that
page, since it would show up there unstyled.

## Views carry no `<style>`

A view holds no `<style>` block unless good design warrants it, and the views
moved so far are held to that (`app_views_spec`).

## How the move was checked

The move changed no pixel. A one-off script dumped every element's computed
style and rect on History, Progress and Learn at 390, 768 and 1280px, at the
default and the largest text, and at 390 and 1280px with the light theme,
before and after; the 15,158 element records matched exactly. Account (with
and without push reminders) and Settings (with a key and without, both
disclosures open) were checked the same way: 10,236 records, no difference.
Today was checked with a fresh set, a partly answered set, a submitted and
reviewed day, the weekend, paused and failed states: 16,660 records, no
difference. The authenticator sheet moved a `<style>` from the body, after
the display sheets, to a link before them, which could have changed a tie
with the light palette. The setup, recovery codes and sign-in-again pages
were checked at 390 and 1280px in the dark and light themes: 904 records, no
difference once the test server's port and the random QR code were set aside. On the generating state only the spinner's rotation differed,
since it was caught at another point in its animation.
