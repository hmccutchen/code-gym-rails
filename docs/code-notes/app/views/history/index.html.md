# app/views/history/index.html.erb

## Layout

The page is a `.card-page` (`phone_cards.css`): on a phone each entry is a
card `max(16px, inset)` from the screen edge, from 600 to 899px the entries
take the container's full width, and at 900px and wider the page's sheet,
`pages/history.css`, puts the rail beside them
(`docs/code-notes/app/assets/stylesheets/pages/history.md`).
The page calls `wide_page`, so its desktop column is 1040px.

`.history-rail` holds the title, the session count and, when there is more
than one page, "Page X of Y". That line is hidden below 900px, because the
pager under the entries already shows it there. It is `aria-hidden`, so a
screen reader hears the page number once, from the pager.

## Why an entry isn't a `.card`

An entry has the card's measurements (16px padding, the shared radius, the
surface background and border) but not the `.card` class.
`phone_cards.css` loads after the layout, and its `.card h2` has the same
specificity as the layout's `.section h2`, so it would shrink every nested
section's title inside "Problems & answers".

## The nested section rule

The layout's 600px rule runs every `.section` to the screen edge, with no
side borders or radius. An entry is already a card, so its nested sections
keep their margins, radius and side borders under 600px. The rule goes when
the layout's bleed rule goes.

## The disclosures and the pager

"Problems & answers" and the review summary are each at least 48px tall, and
the pager's links at least 44px, at every width
(`docs/decisions/desktop-layout.md`). `details.answers` has no margin of its
own, because two 48px summaries already space themselves.
