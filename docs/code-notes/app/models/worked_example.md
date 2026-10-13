# app/models/worked_example.rb

## Why the split is a guess

`guide_worked_example` is one string. The concept-reference prompt asks for
two code fragments followed by prose, but nothing marks where the code ends,
and rows are cached forever, so the Learn page has to split what is already
stored rather than wait for a new format.

The split works a paragraph at a time, where a paragraph is text between
blank lines. A fenced block (three backticks) is always code, so a fragment
with blank lines inside it stays whole when the provider fenced it. Any other
paragraph is code when any line in it looks like code: indented, starting
with a comment marker, or ending in `{`, `}` or `;`. Otherwise it is prose
when it ends like a sentence, or when it holds nothing code-like at all (a
call such as `a.b` or `f(`, or an `=`), so a one-line fragment such as
`Post.includes(:author)` still reads as code while a sentence that lost its
full stop does not. Neighbouring paragraphs of the same kind join
back into one block, so two fragments separated by a blank line render as one
highlighted block, as they were written.

## What a wrong guess costs

A wrong guess changes only how a paragraph looks. Code read as prose shows
unhighlighted in the prose font, which is how every worked example looked
before. Prose read as code shows in a code block. Pseudocode in a
language-independent bucket highlights as plain text either way. Text that
mixes code and prose with no blank line between them stays one paragraph and
takes one kind.
