# app/views/learn/show.html.erb

## Reference fields

The tagline, explanation, code example and senior lens render for any present
reference, whether or not it has a guide. A legacy row, generated before
guides existed, still shows its full reference rather than half of it. Only
the three guide fields and their headings check `guide?`, and only the final
if/else chain decides between guide content and the write-guide control. A row
with a lesson shows the lesson in place of the explanation and the guide's
prose, since the lesson covers both in less space.

## Plain-language guide

The guide's plain-language paragraph follows the reference's explanation
rather than sitting beside it as a separate block: the page gives one account
of the concept, deepened, instead of two competing ones. That ordering is the
visible half of generating the reference and the guide in a single response.

## Code examples disclosure

The code example and worked example are folded so the page reads short on a
phone. The code is still there for anyone who opens it.

## Write-up controls

None of the "not written yet" states is an error. The library is browsable
from the first page load, before anything has been generated.
