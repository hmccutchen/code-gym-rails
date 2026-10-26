# app/controllers/concept_references_controller.rb

## An alternate framing comes back twice

`#explain_differently` answers with the framing as plain text (`alternate`)
and as HTML with its glossary terms marked (`alternate_html`). The page shows
the HTML, so a framing's terms are underlined like every other prose field of
a reference. It sends the plain text back as `prior_alternates`, so the
provider never sees markup and the plain string stays the source of truth.

## Why `alternate_html` escapes again

`glossary_wrap` returns its input unchanged, and not HTML-safe, when it finds
no glossary term; a view escapes that on output, but the page inserts this
field with `innerHTML`. `ERB::Util.html_escape` escapes that plain case and
passes `glossary_wrap`'s own HTML-safe result through untouched, so the field
is escaped whether or not a term matched. The request spec holds both cases.
