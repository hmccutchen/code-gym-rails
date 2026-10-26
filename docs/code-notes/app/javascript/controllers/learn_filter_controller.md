# app/javascript/controllers/learn_filter_controller.js

## What it owns

The Learn index's filter: the text box, the "seen in your sets" checkbox, the
per-entry hiding, the order of entries within each group, and the empty
state. `docs/decisions/learn-search.md` has the reasoning behind the matching
rule.

## The controller element wraps the filter and the list

Entries are not descendants of the filter controls, so the controller mounts on
a wrapper enclosing both. Stimulus targets must be inside the controller
element, and the groups and buckets have to be reachable to hide an emptied
one.

## It matches a rendered attribute

Each entry carries `data-search`, built by `LearnSearchHelper#learn_search_text`:
the label shown on screen, the group heading shown above it, the bucket
heading, the name's glossary forms and its synonyms. Matching against the raw
concept key instead would make typing the visible label find nothing, which
`spec/system/learn_filter_spec.rb` exists to catch. The words of each entry
are split once, in `connect()`.

## How a query matches

A word is a run of letters, digits and `+`, lowercased with accents dropped;
spaces around `+` collapse, so "n + 1" reads as "n+1". Every query word must
match some word of the entry. Under 5 letters it needs an exact or prefix
match; 5 to 7 letters may be 1 edit away and 8 or more 2, measured against
the entry word or its start. The distance is Damerau-Levenshtein, where a
swap of neighbouring letters counts as one edit even beside another edit, so
"arictecture" is two edits from "architecture". A restricted version, which
the first release used, counted that as three. The system spec pins each
limit from both sides, the swap, accent folding and a prefix outranking a
typo.

## Order

Visible entries sort by score within their `ul`, ties in page order, by
moving the `<li>` elements rather than with CSS `order`, so tab and
screen-reader order follow the screen. A query with no words restores page
order exactly, whatever the checkbox hides.

## Groups and buckets hide with their contents

A group whose every entry is hidden is hidden itself, and so is a bucket whose
groups are all empty. Otherwise a filtered page shows headings over nothing.
All three set `display` in the page's sheet, so `hidden` works only because
of the rules that restore it; `docs/code-notes/app/views/learn/index.html.md`
says which ones and what a new rule must not do. Sorting never touches
`hidden`.

## Enter closes the keyboard

The field sits in no form, so Enter would do nothing. `dismiss` blurs it,
which closes a phone's keyboard and lets pull-to-refresh, which waits while a
field has focus, work again. The input also turns off autocorrect and
autocapitalize, so iOS can't rewrite a technical word before it is matched.

## connect() applies the filter

A term typed, the checkbox ticked, or either restored by the browser on Back
before the controller connects reaches no action, so the controls would show a
filter the list does not. `connect()` runs `apply()` once so the list always
matches the controls. `spec/system/deferred_module_spec.rb` stalls this
controller's module, types a typo, and expects the fuzzy match once it
connects.
