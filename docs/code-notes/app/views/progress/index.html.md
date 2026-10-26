# app/views/progress/index.html.erb

## Layout

The page is a `.card-page` (`phone_cards.css`) and calls `wide_page`. On a
phone the legend and each group are cards `max(16px, inset)` from the screen
edge, 16px apart. From 600 to 899px they take the container's full width. At
900px and wider the page's sheet puts the groups two across. Every rule lives
in `pages/progress.css` (`docs/code-notes/app/assets/stylesheets/pages/progress.md`),
linked by `page_stylesheet "progress"`, with the desktop rules last.

`.progress-head` holds the title and the intro, so the card page's 16px gap
doesn't fall between them.

## The legend

The legend is a `details.card`, the collapsible card Settings uses, closed by
default at every width. Open, its 7 entries are a grid: one column on a
phone, two from 600px, four at 900px and wider. On a phone it was taller
than the screen, ahead of the first group.

The note stays outside the disclosure, always visible. The Progress decision
doc relies on it: the page claims no rung is exact because the note says a
rating can still nudge an unlocked section.

## Buckets and groups

A bucket is `.progress-bucket`, not Learn's `.learn-bucket`, so a change to
Learn's layout doesn't reach this page. A bucket with more than one group
also has `.progress-bucket-grouped` and an `h2`. A single-group bucket has
neither: its one disclosure takes the bucket's name, as Learn shows it flat.
`.progress-groups` wraps a bucket's disclosures.

Each group summary is at least 48px tall, each concept row 48px, and each
concept link 44px, at every width (`docs/decisions/desktop-layout.md`). The
link fills the row up to the standing word, so most of the row is the target.

## Group bar

Each group gets one bar, with segment widths set by count. The bars are the
at-a-glance reading, so the concept list below them stays quiet.
