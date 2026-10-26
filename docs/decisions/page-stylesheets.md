# Page stylesheets

Each page that has styles of its own keeps them in one file,
`app/assets/stylesheets/pages/<page>.css`: its phone rules first, then its
desktop rules in one `@media (min-width: 900px)` block at the end. History,
Progress and the Learn index moved first, then Account and Settings, whose
partials' `<style>` blocks joined their page's sheet in the order they
rendered.

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
per page: a second call replaces the first, so a component sheet shared by
several pages needs the helper to take more than one name when the first
such partial moves.

## What stays shared

A rule stays in the layout, or in `phone_cards.css`, when more than one page
uses its class: the featured card (Today and Learn), `.history-pill` (History
and Today's submitted day), `.learn-intro` (Progress and Learn), the
disclosure chevron rule, and the Learn concept and lesson pages' rules, which
aren't part of the page layout work. A partial's styles go in the sheet of
the page it renders on, or, when it renders on several pages, in a small
shared sheet named for the component.

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
