# Searching the Learn list

The filter on `/learn` finds a concept despite typos, partial words, word
forms and common synonyms. "memoizd", "idempotncy", "n plus one" and "n+1"
all reach the concept they mean. It also searches the group and bucket
headings, so "code smell" shows the whole Code smells group.

## What is searched

Each entry's `data-search` holds the words `LearnSearchHelper#learn_search_text`
builds: the humanized name, the group heading when the page shows one, the
bucket heading, every glossary form of the name (`Glossary.forms_for`) and the
entry's synonyms (`LearnSearchTerms::SYNONYMS`). Group and bucket words in
every entry are what make a group name show the whole group, with no special
case in the controller.

Reference text is not searched: no tagline, explanation, guide, ladder or
lesson. Most of it is in `ConceptReference` rows that exist only after
someone presses Prepare, so a content search would miss every ungenerated
concept, and putting it on the page would add hundreds of KB. The new words
add under 1 KB, and dropping the raw underscore key pays for most of that.

## How a query matches

Matching runs in the browser, in `learn_filter_controller.js`, with no
library. The list is about 77 entries for one language and 124 for `mixed`,
which a hand-written scorer handles in a couple of milliseconds per
keystroke, offline included. It is a display filter, not a rule the server
owns; the server still decides what an entry can be found by, because it
renders `data-search`.

Every query word must match some word of the entry. A word under 5 letters
needs an exact or prefix match. A word of 5 to 7 letters may be 1 edit away,
and 8 or more letters 2, where an edit is an insertion, deletion, change or
swap of neighbouring letters, measured against the entry word or its start.
A swap counts as one edit even when another edit sits beside it
(Damerau-Levenshtein distance), so "arictecture" finds Architecture.
The limit began at 4 letters. At that limit "such" matched Missing success
criteria, so 4-letter words became prefix-only.

An exact word scores 3, a prefix 2, and a typo less the more edits it takes.
Entries hide in place, keep their group, and sort by score within it. Every
entry in a group carries the same group and bucket words, so the order inside
a group depends only on the name, form and synonym words. Clearing the field
restores page order. Groups never reorder, so a strong match in a later
bucket stays below a weaker one in an earlier bucket.

## Synonyms

`LearnSearchTerms` is short and hand-written, read only by the helper, and
never sent to a provider. A spec checks the following:

- every key is a concept or a lesson;
- values are lowercase and short;
- no value repeats the name or a glossary form, or names another concept.

A synonym naming a family goes on every member the vocabulary holds.
`solid` is on `open_closed` and `dependency_inversion`, the only SOLID
principles that are concepts today. `conflated_responsibilities` resembles
single responsibility but is not the principle, so it carries no `solid`.

## What was set aside

Postgres `pg_trgm`, full-text search and Basecamp's `rails-active_search`
(alpha, with a Postgres full-text backend) all need an endpoint and a round
trip per query, and stop working offline. The names they would search are
constants, not rows. Full-text search also handles word forms but not typos.
They are worth revisiting only if search grows to cover generated reference
text.

## Mixed-language users

A concept in both the Ruby/Rails and JavaScript vocabularies shows once under
each bucket, since each copy leads to its own page. Adding the language to
the query ("javascript god object") narrows it to one.

## Known limit: a typo near a heading shows the whole group

Group and bucket headings are in every entry's search words, and they follow
the same typo rule as every other word. A query a few letters from a heading
therefore shows that whole group. For example, `score` is one edit from
"Core", so it shows every Core-group concept. Matching heading words only by
exact or prefix match would avoid this, at the cost of a second search
attribute and word list in the controller. It was considered after review
and left as it is: the rule stays the same for every word.
