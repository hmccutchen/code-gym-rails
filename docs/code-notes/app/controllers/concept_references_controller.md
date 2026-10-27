# app/controllers/concept_references_controller.rb

## An alternate framing comes back twice

`#explain_differently` answers with the framing as plain text (`alternate`)
and as HTML with its glossary terms marked (`alternate_html`). The page shows
the HTML, so a framing's terms are underlined like every other prose field of
a reference. It sends the plain text back as `prior_alternates`, so the
provider never sees markup and the plain string stays the source of truth.

## `alternate_html` is already escaped

`glossary_wrap` escapes its input and marks the result `html_safe` whether or
not a term matched, so `alternate_html` is safe to insert with `innerHTML` as
it comes. The request spec checks markup in a framing stays escaped both with
and without a glossary term in it.
